import Foundation
import Luau
import StudioCore

public enum OutputLevel { case info, warn, error }

/// One Luau VM bound to a DataModel (port of lua/LuaRuntime.kt). Scripts run as coroutines,
/// yields are scheduled by `step(dt)`, signals spawn new threads.
public final class ScriptRuntime: TreeListener {
    public let dm: DataModel
    public let isPlay: Bool
    public internal(set) var time: Double = 0
    public private(set) var stopped = false
    /// Output sink (print/warn/errors).
    public var onOutput: (OutputLevel, String) -> Void = { _, s in print(s) }
    /// Engine services (physics, characters, input) provided by a Play session.
    public weak var host: ScriptHost?

    var mainState: LState?
    var alive = true
    var functions: [ScriptFn] = []
    private var namedFunctions: [String: Int32] = [:]
    private var metatableRefs: [String: Int32] = [:]
    private var instanceCacheRef: Int32 = 0

    // Scheduler (LuaRuntime.waiting / deferred / timers / childWaits)
    struct Waiting {
        let co: ThreadHandle; let at: Double; let start: Double
        /// false for fresh threads (task.delay): resume without the (elapsed, time) results.
        var passTime = true
    }
    struct ChildWait { let parent: Instance; let name: String; let co: ThreadHandle; let deadline: Double; let start: Double; var warned: Bool }
    var waiting: [Waiting] = []
    var deferred: [(ThreadHandle, (LState) -> Int32)] = []
    var timers: [(Double, () -> Void)] = []
    var childWaits: [ChildWait] = []
    var mainQueue: [() -> Void] = []

    // Signals: owner -> name -> connections / waiting threads
    var conns: [ObjectIdentifier: [String: [Connection]]] = [:]
    var signalWaiters: [ObjectIdentifier: [String: [ThreadHandle]]] = [:]
    var tweens: [Tween] = []
    var moduleCache: [ObjectIdentifier: LuaRef] = [:]
    var loadingModules: Set<ObjectIdentifier> = []
    /// Per-instance callback properties (OnInvoke, OnServerInvoke...).
    var callbacks: [ObjectIdentifier: [String: LuaRef]] = [:]
    /// Events that run inline (no new thread) in the Android app: kept for ordering semantics.
    let sharedTable: Int32 = 0
    var attributeCache: [ObjectIdentifier: Bool] = [:]
    var dataStores: [String: [String: ScriptValue]] = [:]
    lazy var api = InstanceAPI(rt: self)
    /// RunService:BindToRenderStep bindings.
    var renderStepBindings: [String: Connection] = [:]
    /// Studio selection access for the Selection service (edit runtime / plugins).
    public var selectionProvider: () -> [Instance] = { [] }
    public var selectionSetter: ([Instance]) -> Void = { _ in }

    /// `setup` runs before the global table is sandboxed (read-only), to add host globals.
    public init(dm: DataModel, isPlay: Bool, setup: ((ScriptRuntime) -> Void)? = nil) {
        self.dm = dm
        self.isPlay = isPlay
        luau_swift_set_dispatch(scriptDispatch)
        guard let L = luaL_newstate() else { fatalError("Could not create Luau state") }
        mainState = L
        lua_callbacks(L).pointee.userdata = Unmanaged.passUnretained(self).toOpaque()
        luau_swift_install_interrupt(L)
        lua_setuserdatadtor(L, kUserdataTag, boxDestructor)
        luaL_openlibs(L)

        // Weak-valued cache so one Instance always maps to the same userdata.
        lua_createtable(L, 0, 0)
        lua_createtable(L, 0, 1)
        ScriptRuntime.pushString(L, "v")
        lua_rawsetfield(L, -2, "__mode")
        lua_setmetatable(L, -2)
        instanceCacheRef = lua_ref(L, -1)
        lua_settop(L, -2)

        for t in ScriptObject.allTypeNames { makeMetatable(L, t) }
        DataTypes.install(self, L)
        Globals.install(self, L)
        installPrelude(L)
        installCallWrap(L)
        setup?(self)
        luaL_sandbox(L)
        dm.addListener(self)
    }

    deinit { shutdown() }

    public func shutdown() {
        guard alive else { return }
        stopped = true
        dm.removeListener(self)
        waiting.removeAll(); deferred.removeAll(); timers.removeAll(); childWaits.removeAll()
        conns.removeAll(); signalWaiters.removeAll(); tweens.removeAll(); moduleCache.removeAll(); callbacks.removeAll()
        alive = false
        if let L = mainState { lua_close(L) }
        mainState = nil
    }

    // MARK: output

    func log(_ level: OutputLevel, _ s: String) { if !stopped { onOutput(level, s) } }
    func reportError(_ msg: String) { log(.error, msg) }

    // MARK: functions & metatables

    static func pushString(_ L: LState, _ s: String) {
        var s = s
        s.withUTF8 { b in
            b.withMemoryRebound(to: CChar.self) { c in lua_pushlstring(L, c.baseAddress, c.count) }
        }
    }

    func register(_ fn: @escaping ScriptFn) -> Int32 {
        functions.append(fn)
        return Int32(functions.count - 1)
    }

    /// Push a Swift function. Functions with the same `cacheKey` share one registry slot.
    func pushFunction(_ L: LState, _ name: String, cacheKey: String? = nil, _ fn: @escaping ScriptFn) {
        let id: Int32
        if let k = cacheKey, let existing = namedFunctions[k] {
            id = existing
        } else {
            id = register(fn)
            if let k = cacheKey { namedFunctions[k] = id }
        }
        name.withCString { luau_swift_pushfunction(L, id, $0) }
    }

    private func makeMetatable(_ L: LState, _ typeName: String) {
        lua_createtable(L, 0, 16)
        let ops: [(String, (LuaCall) throws -> Int32)] = [
            ("__index", { [unowned self] c in try self.metaIndex(c) }),
            ("__newindex", { [unowned self] c in try self.metaNewIndex(c) }),
            ("__namecall", { [unowned self] c in try self.metaNamecall(c) }),
            ("__eq", { c in c.push(DataTypes.equal(c.object(1), c.object(2))); return 1 }),
            ("__tostring", { [unowned self] c in c.push(self.describe(c.object(1))); return 1 }),
            ("__add", { c in try DataTypes.arith(c, "+") }),
            ("__sub", { c in try DataTypes.arith(c, "-") }),
            ("__mul", { c in try DataTypes.arith(c, "*") }),
            ("__div", { c in try DataTypes.arith(c, "/") }),
            ("__idiv", { c in try DataTypes.arith(c, "//") }),
            ("__unm", { c in try DataTypes.arith(c, "unm") }),
            ("__lt", { c in try DataTypes.compare(c, lessEqual: false) }),
            ("__le", { c in try DataTypes.compare(c, lessEqual: true) }),
            ("__len", { [unowned self] c in try self.metaLen(c) }),
            ("__iter", { [unowned self] c in try self.metaIter(c) }),
        ]
        for (k, f) in ops {
            pushFunction(L, k, cacheKey: "meta" + k, f)
            lua_rawsetfield(L, -2, k)
        }
        ScriptRuntime.pushString(L, typeName)
        lua_rawsetfield(L, -2, "__type")
        ScriptRuntime.pushString(L, "The metatable is locked")
        lua_rawsetfield(L, -2, "__metatable")
        metatableRefs[typeName] = lua_ref(L, -1)
        lua_settop(L, -2)
    }

    // MARK: boxing

    static func box(_ L: LState, _ i: Int32) -> ObjBox? {
        guard lua_type(L, i) == Int32(LUA_TUSERDATA.rawValue), lua_userdatatag(L, i) == kUserdataTag,
              let p = lua_touserdatatagged(L, i, kUserdataTag) else { return nil }
        guard let raw = p.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee else { return nil }
        return Unmanaged<ObjBox>.fromOpaque(raw).takeUnretainedValue()
    }

    private func newUserdata(_ L: LState, _ o: ScriptObject) {
        let p = lua_newuserdatatagged(L, MemoryLayout<UnsafeMutableRawPointer?>.size, kUserdataTag)!
        p.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = Unmanaged.passRetained(ObjBox(o)).toOpaque()
        if let ref = metatableRefs[o.typeName] {
            lua_rawgeti(L, luau_swift_registryindex(), ref)
            lua_setmetatable(L, -2)
        }
    }

    func pushObject(_ L: LState, _ o: ScriptObject) {
        if case .instance(let i) = o { pushInstance(L, i); return }
        newUserdata(L, o)
    }

    func pushInstance(_ L: LState, _ inst: Instance) {
        let key = Unmanaged.passUnretained(inst).toOpaque()
        lua_rawgeti(L, luau_swift_registryindex(), instanceCacheRef)
        lua_pushlightuserdatatagged(L, key, 0)
        lua_rawget(L, -2)
        if lua_type(L, -1) == Int32(LUA_TUSERDATA.rawValue) {
            lua_remove(L, -2)
            return
        }
        lua_settop(L, -2)
        newUserdata(L, .instance(inst))
        lua_pushlightuserdatatagged(L, key, 0)
        lua_pushvalue(L, -2)
        lua_rawset(L, -4)
        lua_remove(L, -2)
    }

    /// Roblox `typeof`.
    func typeOf(_ L: LState, _ i: Int32) -> String {
        if let b = ScriptRuntime.box(L, i) { return b.obj.typeName }
        return String(cString: lua_typename(L, lua_type(L, i)))
    }

    func describe(_ o: ScriptObject?) -> String {
        guard let o else { return "nil" }
        return DataTypes.describe(o)
    }

    // MARK: Swift <-> Lua values

    func pushValue(_ L: LState, _ v: ScriptValue) {
        switch v {
        case .nil_: lua_pushnil(L)
        case .bool(let b): lua_pushboolean(L, b ? 1 : 0)
        case .number(let n): lua_pushnumber(L, n)
        case .string(let s): ScriptRuntime.pushString(L, s)
        case .object(let o): pushObject(L, o)
        case .function(let r), .opaque(let r): r.push(L)
        case .table(let kv):
            lua_createtable(L, 0, Int32(kv.count))
            for (k, val) in kv {
                pushValue(L, k)
                pushValue(L, val)
                lua_rawset(L, -3)
            }
        }
    }

    /// Read a Lua value into Swift. Tables are copied (depth-limited, cycles cut).
    func readValue(_ L: LState, _ i: Int32, depth: Int = 0) -> ScriptValue {
        let idx = lua_absindex(L, i)
        switch lua_type(L, idx) {
        case Int32(LUA_TNIL.rawValue), -1: return .nil_
        case Int32(LUA_TBOOLEAN.rawValue): return .bool(lua_toboolean(L, idx) != 0)
        case Int32(LUA_TNUMBER.rawValue): return .number(lua_tonumberx(L, idx, nil))
        case Int32(LUA_TSTRING.rawValue):
            var len = 0
            let p = lua_tolstring(L, idx, &len)!
            return .string(String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self))
        case Int32(LUA_TUSERDATA.rawValue):
            if let b = ScriptRuntime.box(L, idx) { return .object(b.obj) }
            return .opaque(refValue(L, idx))
        case Int32(LUA_TFUNCTION.rawValue): return .function(refValue(L, idx))
        case Int32(LUA_TTABLE.rawValue):
            guard depth < 32 else { return .nil_ }
            var out: [(ScriptValue, ScriptValue)] = []
            lua_pushnil(L)
            while lua_next(L, idx) != 0 {
                let k = readValue(L, -2, depth: depth + 1)
                let v = readValue(L, -1, depth: depth + 1)
                out.append((k, v))
                lua_settop(L, -2)
            }
            return .table(out)
        default:
            return .opaque(refValue(L, idx))
        }
    }

    func refValue(_ L: LState, _ i: Int32) -> LuaRef {
        lua_pushvalue(L, i)
        let r = lua_ref(L, -1)
        lua_settop(L, -2)
        return LuaRef(rt: self, ref: r)
    }

    // MARK: metamethod dispatch

    private func metaIndex(_ c: LuaCall) throws -> Int32 {
        guard let o = c.object(1) else { throw LuaError("attempt to index a non-object") }
        let key = c.string(2) ?? ""
        return try api.index(c, o, key)
    }
    private func metaNewIndex(_ c: LuaCall) throws -> Int32 {
        guard let o = c.object(1) else { throw LuaError("attempt to index a non-object") }
        guard let key = c.string(2) else { throw LuaError("invalid property name") }
        try api.newIndex(c, o, key)
        return 0
    }
    private func metaNamecall(_ c: LuaCall) throws -> Int32 {
        guard let p = lua_namecallatom(c.L, nil) else { throw LuaError("namecall without method name") }
        let method = String(cString: p)
        guard let o = c.object(1) else { throw LuaError("Expected ':' not '.' calling member function \(method)") }
        return try api.call(c, o, method)
    }
    private func metaLen(_ c: LuaCall) throws -> Int32 {
        if case .numberSequence(let s)? = c.object(1) { c.push(s.keys.count); return 1 }
        throw LuaError("attempt to get length of a \(c.typeName(1)) value")
    }
    private func metaIter(_ c: LuaCall) throws -> Int32 {
        throw LuaError("attempt to iterate over a \(c.typeName(1)) value")
    }

    /// A function that calls method `name` on its first argument (for `obj.Method` access).
    func pushMethod(_ L: LState, typeName: String, _ name: String) {
        pushFunction(L, name, cacheKey: "method:" + typeName + "." + name) { [unowned self] c in
            guard let o = c.object(1) else { throw LuaError("Expected ':' not '.' calling member function \(name)") }
            return try self.api.call(c, o, name)
        }
    }

    // MARK: threads & scheduling

    /// Strong handle to a coroutine (keeps it alive while scheduled).
    final class ThreadHandle {
        let co: LState
        let ref: Int32
        weak var rt: ScriptRuntime?
        init(rt: ScriptRuntime, co: LState, ref: Int32) { self.rt = rt; self.co = co; self.ref = ref }
        deinit { if let rt, rt.alive, let L = rt.mainState { lua_unref(L, ref) } }
    }

    /// Handle for the thread currently running a Swift call.
    func currentThread(_ L: LState) -> ThreadHandle? {
        guard lua_isyieldable(L) != 0 else { return nil }
        lua_pushthread(L)
        let r = lua_ref(L, -1)
        lua_settop(L, -2)
        return ThreadHandle(rt: self, co: L, ref: r)
    }

    /// New coroutine with `fn` on its stack, ready to resume.
    func newThread(_ fn: LuaRef) -> ThreadHandle? {
        guard let L = mainState, let co = lua_newthread(L) else { return nil }
        let r = lua_ref(L, -1)
        lua_settop(L, -2)
        fn.push(co)
        return ThreadHandle(rt: self, co: co, ref: r)
    }

    private var resumeDepth = 0

    /// Resume a coroutine, pushing arguments with `args`. Errors are reported to Output.
    @discardableResult
    func resume(_ t: ThreadHandle, _ args: (LState) -> Int32 = { _ in 0 }) -> Bool {
        guard !stopped, alive else { return false }
        let st = lua_status(t.co)
        // Fresh threads have status OK with the function on the stack; yielded ones are YIELD.
        guard st == Int32(LUA_YIELD.rawValue) || (st == Int32(LUA_OK.rawValue) && lua_gettop(t.co) > 0) else { return false }
        let n = args(t.co)
        if resumeDepth == 0 { luau_swift_set_deadline(lua_clock() + 10) }
        resumeDepth += 1
        let status = lua_resume(t.co, nil, n)
        resumeDepth -= 1
        if resumeDepth == 0 { luau_swift_set_deadline(0) }
        if status == Int32(LUA_OK.rawValue) || status == Int32(LUA_YIELD.rawValue) {
            if status == Int32(LUA_OK.rawValue) { lua_settop(t.co, 0) }
            return true
        }
        var msg = "error"
        var len = 0
        if let p = lua_tolstring(t.co, -1, &len) {
            msg = String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
        } else if let b = ScriptRuntime.box(t.co, -1) {
            msg = DataTypes.describe(b.obj)
        }
        var trace = ""
        if let tr = lua_debugtrace(t.co) { trace = String(cString: tr) }
        reportError(msg + (trace.isEmpty ? "" : "\nStack Begin\n" + trace.trimmingCharacters(in: .newlines) + "\nStack End"))
        lua_settop(t.co, 0)
        return false
    }

    /// Start `fn` in a new thread right now.
    @discardableResult
    func spawn(_ fn: LuaRef, _ args: @escaping (LState) -> Int32 = { _ in 0 }) -> ThreadHandle? {
        guard let t = newThread(fn) else { return nil }
        resume(t, args)
        return t
    }

    func yieldFor(_ c: LuaCall, _ seconds: Double) throws -> Int32 {
        guard let t = currentThread(c.L) else { throw LuaError("attempt to yield across a non-yieldable boundary (use task.spawn)") }
        waiting.append(Waiting(co: t, at: time + max(seconds, 0), start: time))
        return c.yield(0)
    }

    func delay(_ seconds: Double, _ t: ThreadHandle, passTime: Bool = false) {
        waiting.append(Waiting(co: t, at: time + max(seconds, 0), start: time, passTime: passTime))
    }
    func defer_(_ t: ThreadHandle, _ args: @escaping (LState) -> Int32 = { _ in 0 }) { deferred.append((t, args)) }
    func after(_ seconds: Double, _ fn: @escaping () -> Void) { timers.append((time + max(seconds, 0), fn)) }

    func cancel(_ co: LState) {
        waiting.removeAll { $0.co.co == co }
        deferred.removeAll { $0.0.co == co }
        childWaits.removeAll { $0.co.co == co }
    }

    func waitForChild(_ c: LuaCall, _ parent: Instance, _ name: String, timeout: Double?) throws -> Int32 {
        if let found = parent.findFirstChild(name) { c.push(found); return 1 }
        guard let t = currentThread(c.L) else { throw LuaError("WaitForChild must be called from a yieldable thread") }
        childWaits.append(ChildWait(parent: parent, name: name, co: t, deadline: timeout.map { time + $0 } ?? .greatestFiniteMagnitude,
                                    start: time, warned: false))
        return c.yield(0)
    }

    func checkChildWaits() {
        let done = childWaits.filter { $0.parent.findFirstChild($0.name) != nil }
        guard !done.isEmpty else { return }
        childWaits.removeAll { w in done.contains { $0.co === w.co } }
        for w in done {
            let child = w.parent.findFirstChild(w.name)
            deferred.append((w.co, { [unowned self] L in self.pushInstanceOrNil(L, child); return 1 }))
        }
    }

    func pushInstanceOrNil(_ L: LState, _ i: Instance?) { if let i { pushInstance(L, i) } else { lua_pushnil(L) } }

    /// Advance the scheduler (port of LuaRuntime.step).
    public func step(_ dt: Double) {
        guard !stopped else { return }
        time += dt
        let q = mainQueue; mainQueue.removeAll()
        for f in q { f() }

        if !waiting.isEmpty {
            let due = waiting.filter { $0.at <= time }.sorted { $0.at < $1.at }
            if !due.isEmpty {
                let t0 = DispatchTime.now().uptimeNanoseconds
                var ran = Set<ObjectIdentifier>()
                for w in due {
                    if !ran.isEmpty && DispatchTime.now().uptimeNanoseconds - t0 > 8_000_000 { break }
                    ran.insert(ObjectIdentifier(w.co))
                    waiting.removeAll { $0.co === w.co }
                    let elapsed = time - w.start, now = time
                    if w.passTime {
                        resume(w.co) { L in lua_pushnumber(L, elapsed); lua_pushnumber(L, now); return 2 }
                    } else {
                        resume(w.co)
                    }
                }
            }
        }
        if !timers.isEmpty {
            let due = timers.filter { $0.0 <= time }
            timers.removeAll { $0.0 <= time }
            for (_, f) in due { f() }
        }
        if !deferred.isEmpty {
            let d = deferred; deferred.removeAll()
            for (t, a) in d { resume(t, a) }
        }
        if !childWaits.isEmpty {
            var timedOut: [ThreadHandle] = []
            for k in childWaits.indices.reversed() {
                if !childWaits[k].warned && time - childWaits[k].start > 5 && childWaits[k].deadline == .greatestFiniteMagnitude {
                    childWaits[k].warned = true
                    log(.warn, "Infinite yield possible on '\(childWaits[k].parent.fullName()):WaitForChild(\"\(childWaits[k].name)\")'")
                }
                if time >= childWaits[k].deadline { timedOut.append(childWaits[k].co); childWaits.remove(at: k) }
            }
            for t in timedOut { resume(t) { L in lua_pushnil(L); return 1 } }
        }
        stepTweens(Float(dt))
    }

    // MARK: signals

    func hasConn(_ owner: AnyObject, _ name: String) -> Bool {
        let k = ObjectIdentifier(owner)
        return !(conns[k]?[name]?.isEmpty ?? true) || !(signalWaiters[k]?[name]?.isEmpty ?? true)
    }

    func connect(_ owner: AnyObject, _ name: String, _ fn: LuaRef, once: Bool) -> Connection {
        let c = Connection(owner: owner, name: name, fn: fn, once: once)
        conns[ObjectIdentifier(owner), default: [:]][name, default: []].append(c)
        return c
    }

    func disconnect(_ c: Connection) {
        c.connected = false
        guard let o = c.ownerKey else { return }
        conns[o]?[c.name]?.removeAll { $0 === c }
    }

    func disconnectTree(_ i: Instance) {
        let k = ObjectIdentifier(i)
        conns[k] = nil; signalWaiters[k] = nil; callbacks[k] = nil
        for c in i.children { disconnectTree(c) }
    }

    func waitSignal(_ c: LuaCall, _ owner: AnyObject, _ name: String) throws -> Int32 {
        guard let t = currentThread(c.L) else { throw LuaError("Wait can only be called from a yieldable thread") }
        signalWaiters[ObjectIdentifier(owner), default: [:]][name, default: []].append(t)
        return c.yield(0)
    }

    /// Fire a signal: every connection runs in its own new thread, waiting threads resume.
    func fire(_ owner: AnyObject, _ name: String, _ args: [ScriptValue] = []) {
        guard !stopped else { return }
        let k = ObjectIdentifier(owner)
        let push: (LState) -> Int32 = { [unowned self] L in
            for a in args { self.pushValue(L, a) }
            return Int32(args.count)
        }
        if let list = conns[k]?[name], !list.isEmpty {
            for c in list where c.connected {
                if c.once { disconnect(c) }
                spawn(c.fn, push)
            }
        }
        if let ws = signalWaiters[k]?[name] {
            signalWaiters[k]?[name] = nil
            for t in ws { resume(t, push) }
        }
    }

    // MARK: TreeListener (Instance events)

    public func childAdded(_ parent: Instance, _ child: Instance) {
        guard !stopped else { return }
        if hasConn(parent, "ChildAdded") { fire(parent, "ChildAdded", [.object(.instance(child))]) }
        var p: Instance? = parent
        while let cur = p {
            if hasConn(cur, "DescendantAdded") {
                fire(cur, "DescendantAdded", [.object(.instance(child))])
                for d in child.descendants() { fire(cur, "DescendantAdded", [.object(.instance(d))]) }
            }
            p = cur.parent
        }
        notifyAncestry(child)
        if !childWaits.isEmpty { checkChildWaits() }
        for tag in CollectionTags.tags(of: child) { fire(CollectionTags.signalOwner(self, tag), "Added", [.object(.instance(child))]) }
        host?.childAdded(parent, child)
    }

    public func childRemoved(_ parent: Instance, _ child: Instance) {
        guard !stopped else { return }
        if hasConn(parent, "ChildRemoved") { fire(parent, "ChildRemoved", [.object(.instance(child))]) }
        var p: Instance? = parent
        while let cur = p {
            if hasConn(cur, "DescendantRemoving") { fire(cur, "DescendantRemoving", [.object(.instance(child))]) }
            p = cur.parent
        }
        notifyAncestry(child)
        if child.destroyed {
            if hasConn(child, "Destroying") { fire(child, "Destroying") }
            disconnectTree(child)
        }
        host?.childRemoved(parent, child)
    }

    public func propChanged(_ inst: Instance, _ name: String) {
        guard !stopped else { return }
        if name == "Name" && !childWaits.isEmpty { checkChildWaits() }
        if isPlay && name == "Disabled" && inst.isA("BaseScript") && inst.get("Disabled")?.asBool == false { host?.maybeRunScript(inst) }
        host?.propChanged(inst, name)
        guard let m = conns[ObjectIdentifier(inst)] else { return }
        let disp = PropAccess.display(name)
        if m["Changed"] != nil {
            if inst.isA("ValueBase") && disp == "Value" {
                fire(inst, "Changed", [api.getValue(inst, "Value")])
            } else {
                fire(inst, "Changed", [.string(disp)])
            }
        }
        if m["Changed:" + disp] != nil { fire(inst, "Changed:" + disp) }
        if disp == "CFrame" {
            if m["Changed:Position"] != nil { fire(inst, "Changed:Position") }
            if m["Changed:Orientation"] != nil { fire(inst, "Changed:Orientation") }
        }
        if disp == "Health", m["HealthChanged"] != nil {
            fire(inst, "HealthChanged", [api.getValue(inst, "Health")])
        }
    }

    func notifyAncestry(_ i: Instance) {
        guard !conns.isEmpty else { return }
        if hasConn(i, "AncestryChanged") { fire(i, "AncestryChanged", [.object(.instance(i)), i.parent.map { .object(.instance($0)) } ?? .nil_]) }
        for d in i.descendants() where conns[ObjectIdentifier(d)] != nil {
            if hasConn(d, "AncestryChanged") { fire(d, "AncestryChanged", [.object(.instance(d)), d.parent.map { .object(.instance($0)) } ?? .nil_]) }
        }
    }

    /// Add a table of Swift functions as a global (only valid inside the init `setup` hook).
    public func addGlobalTable(_ name: String, _ fns: [String: (ScriptCall) throws -> Int32]) {
        guard let L = mainState else { return }
        lua_createtable(L, 0, Int32(fns.count))
        for (k, f) in fns {
            pushFunction(L, k) { c in try f(ScriptCall(c)) }
            lua_rawsetfield(L, -2, k)
        }
        lua_setfield(L, luau_swift_globalsindex(), name)
    }

    // MARK: compiling & running

    /// Compile and load `source` onto `L` as a function. Throws the syntax error message.
    func load(_ L: LState, _ source: String, chunk: String) throws {
        var size = 0
        guard let bc = source.withCString({ luau_swift_compile($0, source.utf8.count, &size) }) else {
            throw LuaError("compile failed")
        }
        defer { free(bc) }
        let status = ("=" + chunk).withCString { luau_load(L, $0, bc, size, 0) }
        if status != 0 {
            var len = 0
            let msg = lua_tolstring(L, -1, &len).map { String(decoding: UnsafeRawBufferPointer(start: $0, count: len), as: UTF8.self) } ?? "syntax error"
            lua_settop(L, -2)
            throw LuaError(msg)
        }
    }

    /// New sandboxed thread whose globals have `script` set (LuaRuntime.envFor).
    func scriptThread(for script: Instance?) -> ThreadHandle? {
        guard let L = mainState, let co = lua_newthread(L) else { return nil }
        let r = lua_ref(L, -1)
        lua_settop(L, -2)
        luaL_sandboxthread(co)
        pushInstanceOrNil(co, script)
        lua_rawsetfield(co, luau_swift_globalsindex(), "script")
        return ThreadHandle(rt: self, co: co, ref: r)
    }

    /// Run a Script / LocalScript (LuaRuntime.runScript).
    public func runScript(_ script: Instance) {
        guard case .string(let src)? = script.get("Source") else { return }
        guard let t = scriptThread(for: script) else { return }
        do {
            try load(t.co, src, chunk: script.fullName())
            resume(t)
        } catch let e as LuaError {
            reportError(e.message)
        } catch {}
    }

    /// Command bar: run code with `script` = nil.
    public func runCommand(_ code: String) {
        guard let t = scriptThread(for: nil) else { return }
        do {
            try load(t.co, code, chunk: "CommandBar")
            resume(t)
        } catch let e as LuaError { reportError(e.message) } catch {}
    }

    private func installPrelude(_ L: LState) {
        let src = """
        local begin, finish = ...
        return function(m)
            local cached, v = begin(m)
            if cached then return v end
            local ok, res = pcall(v)
            return finish(m, ok, res)
        end
        """
        do { try load(L, src, chunk: "require") } catch { fatalError("prelude: \(error)") }
        pushFunction(L, "requireBegin") { [unowned self] c in try self.requireBegin(c) }
        pushFunction(L, "requireFinish") { [unowned self] c in try self.requireFinish(c) }
        if lua_pcall(L, 2, 1, 0) != 0 { fatalError("prelude failed") }
        lua_setfield(L, luau_swift_globalsindex(), "require")
    }

    private func requireBegin(_ c: LuaCall) throws -> Int32 {
        if let n = c.number(1) {
            throw LuaError("require(\(Int(n))): loading modules by asset id needs network access (not available)")
        }
        guard let m = c.instance(1) else { throw LuaError("Attempted to call require with invalid argument(s).") }
        let k = ObjectIdentifier(m)
        if let cached = moduleCache[k] { c.push(true); cached.push(c.L); return 2 }
        guard m.isA("ModuleScript") else { throw LuaError("Attempted to call require with invalid argument(s).") }
        if loadingModules.contains(k) { throw LuaError("Requested module was required recursively") }
        loadingModules.insert(k)
        guard let t = scriptThread(for: m) else { throw LuaError("could not create module thread") }
        let src = m.get("Source")?.asString ?? ""
        do { try load(t.co, src, chunk: m.fullName()) } catch { loadingModules.remove(k); throw error }
        c.push(false)
        lua_xmove(t.co, c.L, 1)
        return 2
    }

    private func requireFinish(_ c: LuaCall) throws -> Int32 {
        guard let m = c.instance(1) else { throw LuaError("bad module") }
        let k = ObjectIdentifier(m)
        loadingModules.remove(k)
        if !c.bool(2) {
            let msg = c.string(3) ?? "error"
            throw LuaError("Requested module experienced an error while loading: \(msg)")
        }
        if c.isNil(3) { throw LuaError("Module code did not return exactly one value") }
        moduleCache[k] = c.ref(3)
        lua_pushvalue(c.L, 3)
        return 1
    }

    // MARK: calling Lua from Swift methods (BindableFunction:Invoke, RemoteFunction, UpdateAsync...)

    var callWrapRef: LuaRef?
    private var nextCallToken: Int32 = 1
    private var callResults: [Int32: (Bool, [ScriptValue])] = [:]
    private var callWaiters: [Int32: ThreadHandle] = [:]

    /// Run `fn(args...)` in a new thread. Its results are returned to the calling script; if the
    /// function yields, the caller yields too and is resumed with the results later.
    func callLua(_ c: LuaCall, _ fn: LuaRef, _ args: [ScriptValue]) throws -> Int32 {
        guard let wrap = callWrapRef, let t = newThread(wrap) else { throw LuaError("callback unavailable") }
        let token = nextCallToken
        nextCallToken += 1
        resume(t) { [unowned self] L in
            lua_pushinteger(L, token)
            fn.push(L)
            for a in args { self.pushValue(L, a) }
            return Int32(2 + args.count)
        }
        if let (ok, vals) = callResults.removeValue(forKey: token) {
            if !ok { throw LuaError(vals.first.flatMap { if case .string(let s) = $0 { return s }; return nil } ?? "error in callback") }
            for v in vals { c.push(v) }
            return Int32(vals.count)
        }
        guard let me = currentThread(c.L) else { throw LuaError("callback yielded in a non-yieldable context") }
        callWaiters[token] = me
        return c.yield(0)
    }

    /// Called by the Lua wrapper when a callLua function finishes.
    func callDone(_ c: LuaCall) -> Int32 {
        let token = Int32(c.number(1) ?? 0)
        let ok = c.bool(2)
        var vals: [ScriptValue] = []
        if c.top >= 3 { for i in 3...c.top { vals.append(readValue(c.L, i)) } }
        if let waiter = callWaiters.removeValue(forKey: token) {
            if ok {
                resume(waiter) { [unowned self] L in for v in vals { self.pushValue(L, v) }; return Int32(vals.count) }
            } else {
                let msg: String = { if case .string(let s)? = vals.first { return s }; return "error in callback" }()
                ScriptRuntime.pushString(waiter.co, msg)
                lua_resumeerror(waiter.co, nil)
            }
        } else {
            callResults[token] = (ok, vals)
        }
        return 0
    }

    func installCallWrap(_ L: LState) {
        let src = """
        local done = ...
        return function(token, fn, ...)
            local r = table.pack(pcall(fn, ...))
            done(token, table.unpack(r, 1, r.n))
        end
        """
        do { try load(L, src, chunk: "callback") } catch { fatalError("callwrap: \(error)") }
        pushFunction(L, "callDone") { [unowned self] c in self.callDone(c) }
        if lua_pcall(L, 1, 1, 0) != 0 { fatalError("callwrap failed") }
        callWrapRef = refValue(L, -1)
        lua_settop(L, -2)
    }

    // MARK: tweens

    func playTween(_ tw: Tween) {
        // A new tween on the same property cancels the old one (Roblox behaviour).
        for other in tweens where other !== tw && other.inst === tw.inst && other.goals.keys.contains(where: { tw.goals[$0] != nil }) {
            other.state = .cancelled
        }
        tweens.removeAll { $0.state == .cancelled }
        if !tweens.contains(where: { $0 === tw }) { tweens.append(tw) }
        if tw.state == .paused {
            tw.state = tw.start.isEmpty ? .delayed : .playing
            return
        }
        tw.elapsed = 0; tw.reversing = false; tw.repeatsDone = 0; tw.start = [:]
        // stepTweens captures start values once the delay (possibly 0) has passed.
        tw.state = .delayed
    }

    private func stepTweens(_ dt: Float) {
        guard !tweens.isEmpty else { return }
        for tw in tweens {
            guard tw.state == .playing || tw.state == .delayed else { continue }
            tw.elapsed += dt
            if tw.state == .delayed {
                guard tw.elapsed >= tw.info.delay else { continue }
                tw.state = .playing
                tw.elapsed = 0
                tw.start = [:]
                for k in tw.goals.keys { tw.start[k] = api.getValue(tw.inst, k) }
            }
            let dur = max(tw.info.time, 1e-4)
            var a = min(1, max(0, tw.elapsed / dur))
            if tw.reversing { a = 1 - a }
            let e = Easing.ease(style: tw.info.style, direction: tw.info.direction, a)
            for (k, goal) in tw.goals {
                if let s = tw.start[k], let v = DataTypes.lerpValue(s, goal, e) { try? api.setValue(tw.inst, k, v) }
            }
            if tw.elapsed >= dur {
                if tw.info.reverses && !tw.reversing {
                    tw.reversing = true; tw.elapsed = 0
                } else if tw.info.repeatCount < 0 || tw.repeatsDone < tw.info.repeatCount {
                    tw.repeatsDone += 1; tw.reversing = false; tw.elapsed = 0
                } else {
                    tw.state = .completed
                    tweens.removeAll { $0 === tw }
                    fire(tw, "Completed", [.object(.enumItem(EnumItem(enumType: "PlaybackState", name: "Completed", value: 4)))])
                }
            }
        }
    }
}

/// Hooks a Play session provides to scripts (port of the PlaySession calls in the Android runtime).
public protocol ScriptHost: AnyObject {
    func childAdded(_ parent: Instance, _ child: Instance)
    func childRemoved(_ parent: Instance, _ child: Instance)
    func propChanged(_ inst: Instance, _ name: String)
    func maybeRunScript(_ s: Instance)
    func raycast(origin: Vector3, direction: Vector3, params: RaycastParamsV?) -> RaycastResultV?
    func velocity(of part: Instance) -> Vector3
    func setVelocity(of part: Instance, _ v: Vector3)
    func applyImpulse(_ part: Instance, _ impulse: Vector3)
    func touchingParts(_ part: Instance) -> [Instance]
    func humanoidMove(_ humanoid: Instance, direction: Vector3)
    func humanoidMoveTo(_ humanoid: Instance, target: Vector3)
    func humanoidJump(_ humanoid: Instance)
    func moveDirection(_ humanoid: Instance) -> Vector3
    func isGrounded(_ humanoid: Instance) -> Bool
    func loadTrack(owner: Instance, animation: Instance) -> AnimTrackRef?
    func playTrack(_ t: AnimTrackRef, fade: Float, weight: Float, speed: Float)
    func stopTrack(_ t: AnimTrackRef, fade: Float)
    func adjustTrack(_ t: AnimTrackRef, speed: Float?, weight: Float?, looped: Bool?, time: Float?)
    func playingTracks(_ owner: Instance) -> [AnimTrackRef]
    func playSound(_ sound: Instance)
    func stopSound(_ sound: Instance)
    func viewportSize() -> Vector2
    func cameraRay(x: Float, y: Float) -> Ray
    func worldToViewport(_ p: Vector3) -> (Vector3, Bool)
    func keyDown(_ key: String) -> Bool
    func respawn(_ player: Instance)
    func equipTool(_ humanoid: Instance, _ tool: Instance)
    func unequipTools(_ humanoid: Instance)
    func bindAction(_ name: String, _ fn: LuaRef, touchButton: Bool, keys: [String])
    func unbindAction(_ name: String)
    func setActionTitle(_ name: String, _ title: String)
    func chat(_ player: Instance?, _ text: String)
}
