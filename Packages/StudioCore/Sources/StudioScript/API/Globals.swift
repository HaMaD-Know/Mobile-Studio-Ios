import Foundation
import Luau
import StudioCore

/// Roblox global functions and libraries (port of lua/RobloxGlobals.kt). Luau's own libraries
/// (table.find/clone, string.split, math.clamp/noise, utf8, bit32, buffer...) are built in.
enum Globals {
    static func install(_ rt: ScriptRuntime, _ L: LState) {
        func global(_ name: String, _ f: @escaping ScriptFn) {
            rt.pushFunction(L, name, f)
            lua_setfield(L, luau_swift_globalsindex(), name)
        }
        func globalValue(_ name: String, _ o: ScriptObject) {
            rt.pushObject(L, o)
            lua_setfield(L, luau_swift_globalsindex(), name)
        }

        // Output
        let printFn: (OutputLevel) -> ScriptFn = { level in
            { c in
                var parts: [String] = []
                let n = c.top
                if n > 0 {
                    for i in 1...n {
                        if luau_swift_tostring(c.L, i) == 0, let s = c.string(-1) { parts.append(s) } else { parts.append(c.typeName(i)) }
                        lua_settop(c.L, -2)
                    }
                }
                c.rt.log(level, parts.joined(separator: " "))
                return 0
            }
        }
        global("print", printFn(.info))
        global("warn", printFn(.warn))
        global("printidentity") { c in c.rt.log(.info, "Current identity is 2"); return 0 }

        // Scheduling
        let waitFn: ScriptFn = { c in try c.rt.yieldFor(c, max(c.optNumber(1, 0.03), 0.03)) }
        global("wait", waitFn)
        global("Wait", waitFn)
        global("delay") { c in
            guard c.isFunction(2) else { throw c.argError(2, "function", "delay") }
            if let t = c.rt.newThread(c.ref(2)) { c.rt.delay(max(c.optNumber(1, 0.03), 0.03), t, passTime: false) }
            return 0
        }
        global("spawn") { c in
            guard c.isFunction(1) else { throw c.argError(1, "function", "spawn") }
            if let t = c.rt.newThread(c.ref(1)) { c.rt.delay(0.03, t, passTime: false) }
            return 0
        }
        global("tick") { c in c.push(Date().timeIntervalSince1970); return 1 }
        global("time") { c in c.push(c.rt.time); return 1 }
        global("elapsedTime") { c in c.push(c.rt.time); return 1 }
        global("version") { c in c.push("0.600.0.6000000"); return 1 }
        global("gcinfo") { c in c.push(Double(lua_gc(c.L, 3, 0))); return 1 }
        global("typeof") { c in c.push(c.rt.typeOf(c.L, 1)); return 1 }
        global("settings") { c in c.push(c.rt.dm.getService("Settings")); return 1 }
        global("UserSettings") { c in c.push(c.rt.dm.getService("UserSettings")); return 1 }
        global("loadstring") { c in
            let src = try c.checkString(1, "loadstring")
            let chunk = c.optString(2) ?? "loadstring"
            do {
                try c.rt.load(c.L, src, chunk: chunk)
                return 1
            } catch let e as LuaError {
                c.pushNil(); c.push(e.message); return 2
            }
        }
        // ypcall is the legacy name of pcall.
        lua_getfield(L, luau_swift_globalsindex(), "pcall")
        lua_setfield(L, luau_swift_globalsindex(), "ypcall")

        // task library
        lua_createtable(L, 0, 8)
        func taskFn(_ name: String, _ f: @escaping ScriptFn) {
            rt.pushFunction(L, "task." + name, f)
            lua_rawsetfield(L, -2, name)
        }
        taskFn("wait") { c in try c.rt.yieldFor(c, c.optNumber(1, 0)) }
        taskFn("spawn") { c in
            let t = try threadArg(c, 1, "task.spawn")
            let nargs = c.top
            if nargs > 0 { lua_xmove(c.L, t.co, nargs) }
            pushThread(c, t)
            c.rt.resume(t) { _ in nargs }
            return 1
        }
        taskFn("defer") { c in
            let t = try threadArg(c, 1, "task.defer")
            let nargs = c.top
            if nargs > 0 { lua_xmove(c.L, t.co, nargs) }
            pushThread(c, t)
            c.rt.defer_(t) { _ in nargs }
            return 1
        }
        taskFn("delay") { c in
            let secs = c.optNumber(1, 0)
            let t = try threadArg(c, 2, "task.delay")
            let nargs = c.top - 1
            if nargs > 0 { lua_xmove(c.L, t.co, nargs) }
            pushThread(c, t)
            c.rt.delay(secs, t, passTime: false)
            return 1
        }
        taskFn("cancel") { c in
            guard let co = lua_tothread(c.L, 1) else { throw c.argError(1, "thread", "task.cancel") }
            c.rt.cancel(co)
            return 0
        }
        taskFn("synchronize") { _ in 0 }
        taskFn("desynchronize") { _ in 0 }
        lua_setreadonly(L, -1, 1)
        lua_setfield(L, luau_swift_globalsindex(), "task")

        // Instance library
        lua_createtable(L, 0, 2)
        rt.pushFunction(L, "Instance.new") { c in
            let cls = try c.checkString(1, "Instance.new")
            guard !cls.isEmpty, !ClassDb.isServiceName(cls) || ["Folder", "Configuration"].contains(cls) else {
                throw LuaError("Unable to create an Instance of type \"\(cls)\"")
            }
            let inst = InstanceFactory.create(cls)
            if let p = c.instance(2) { try c.rt.api.setParent(inst, p) }
            c.push(inst)
            return 1
        }
        lua_rawsetfield(L, -2, "new")
        rt.pushFunction(L, "Instance.fromExisting") { c in
            let src = try c.checkInstance(1, "Instance.fromExisting")
            let i = Instance(src.className)
            i.props.merge(src.props)
            for (k, v) in src.propTypes { i.propTypes[k] = v }
            c.push(i)
            return 1
        }
        lua_rawsetfield(L, -2, "fromExisting")
        lua_setreadonly(L, -1, 1)
        lua_setfield(L, luau_swift_globalsindex(), "Instance")

        // DataModel shortcuts
        globalValue("game", .instance(rt.dm))
        globalValue("Game", .instance(rt.dm))
        globalValue("workspace", .instance(rt.dm.workspace))
        globalValue("Workspace", .instance(rt.dm.workspace))

        lua_createtable(L, 0, 0)
        lua_setfield(L, luau_swift_globalsindex(), "shared")

        // DateTime (minimal): now(), fromUnixTimestamp(), UnixTimestamp(Millis)
        lua_createtable(L, 0, 4)
        rt.pushFunction(L, "DateTime.now") { c in pushDateTime(c, Date().timeIntervalSince1970); return 1 }
        lua_rawsetfield(L, -2, "now")
        rt.pushFunction(L, "DateTime.fromUnixTimestamp") { c in pushDateTime(c, try c.checkNumber(1)); return 1 }
        lua_rawsetfield(L, -2, "fromUnixTimestamp")
        rt.pushFunction(L, "DateTime.fromUnixTimestampMillis") { c in pushDateTime(c, try c.checkNumber(1) / 1000); return 1 }
        lua_rawsetfield(L, -2, "fromUnixTimestampMillis")
        lua_setreadonly(L, -1, 1)
        lua_setfield(L, luau_swift_globalsindex(), "DateTime")
    }

    /// DateTime values are plain read-only tables with the timestamp fields scripts use.
    private static func pushDateTime(_ c: LuaCall, _ t: Double) {
        lua_createtable(c.L, 0, 3)
        c.push(floor(t)); lua_rawsetfield(c.L, -2, "UnixTimestamp")
        c.push(floor(t * 1000)); lua_rawsetfield(c.L, -2, "UnixTimestampMillis")
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t))
        c.pushFn("ToIsoDate") { c2 in c2.push(iso); return 1 }
        lua_rawsetfield(c.L, -2, "ToIsoDate")
    }

    /// Argument that is either a function (wrapped in a new thread) or an existing coroutine.
    private static func threadArg(_ c: LuaCall, _ i: Int32, _ fn: String) throws -> ScriptRuntime.ThreadHandle {
        if c.isFunction(i) {
            guard let t = c.rt.newThread(c.ref(i)) else { throw LuaError("could not create thread") }
            lua_remove(c.L, i)
            return t
        }
        if let co = lua_tothread(c.L, i) {
            let r = c.ref(i)
            lua_remove(c.L, i)
            return ScriptRuntime.ThreadHandle(rt: c.rt, co: co, ref: retain(r))
        }
        throw c.argError(i, "function or thread", fn)
    }

    /// Keep a LuaRef's registry slot owned by a ThreadHandle (the handle unrefs it).
    private static func retain(_ r: LuaRef) -> Int32 {
        guard let L = r.rt?.mainState else { return 0 }
        r.push(L)
        let n = lua_ref(L, -1)
        lua_settop(L, -2)
        return n
    }

    private static func pushThread(_ c: LuaCall, _ t: ScriptRuntime.ThreadHandle) {
        lua_rawgeti(c.L, luau_swift_registryindex(), t.ref)
    }
}
