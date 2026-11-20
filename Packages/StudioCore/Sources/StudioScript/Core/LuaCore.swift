import Foundation
import Luau
import StudioCore

/// Error raised from Swift into Lua (becomes a Lua error with script position).
public struct LuaError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

typealias LState = OpaquePointer

/// Swift function callable from Lua. Returns the number of results pushed (or a lua_yield result).
typealias ScriptFn = (LuaCall) throws -> Int32

/// A value stored in a Lua userdata. Value types are boxed; reference types keep identity.
final class ObjBox {
    let obj: ScriptObject
    init(_ o: ScriptObject) { obj = o }
}

/// Every userdata kind the Roblox API exposes (port of lua/LuaTypes.kt's wrapped classes).
enum ScriptObject {
    case instance(Instance)
    case vector3(Vector3)
    case vector2(Vector2)
    case cframe(CFrame)
    case color3(Color3)
    case brickColor(Int)
    case udim(UDim)
    case udim2(UDim2)
    case ray(Ray)
    case rect(Rect)
    case numberRange(NumberRange)
    case numberSequence(NumberSequence)
    case numberKey(NumberKey)
    case colorSequence(ColorSequence)
    case colorKey(ColorKey)
    case vector3int16(Vector3int16)
    case region3(Region3)
    case physicalProps(PhysicalProps)
    case font(FontValue)
    case faces(Faces)
    case axes(Axes)
    case tweenInfo(TweenInfoV)
    case random(RandomGen)
    case enumLib
    case enumType(String)
    case enumItem(EnumItem)
    case signal(SignalRef)
    case connection(Connection)
    case raycastParams(RaycastParamsV)
    case overlapParams(OverlapParamsV)
    case raycastResult(RaycastResultV)
    case tween(Tween)
    case track(AnimTrackRef)

    var typeName: String {
        switch self {
        case .instance: "Instance"
        case .vector3: "Vector3"
        case .vector2: "Vector2"
        case .cframe: "CFrame"
        case .color3: "Color3"
        case .brickColor: "BrickColor"
        case .udim: "UDim"
        case .udim2: "UDim2"
        case .ray: "Ray"
        case .rect: "Rect"
        case .numberRange: "NumberRange"
        case .numberSequence: "NumberSequence"
        case .numberKey: "NumberSequenceKeypoint"
        case .colorSequence: "ColorSequence"
        case .colorKey: "ColorSequenceKeypoint"
        case .vector3int16: "Vector3int16"
        case .region3: "Region3"
        case .physicalProps: "PhysicalProperties"
        case .font: "Font"
        case .faces: "Faces"
        case .axes: "Axes"
        case .tweenInfo: "TweenInfo"
        case .random: "Random"
        case .enumLib: "Enums"
        case .enumType: "Enum"
        case .enumItem: "EnumItem"
        case .signal: "RBXScriptSignal"
        case .connection: "RBXScriptConnection"
        case .raycastParams: "RaycastParams"
        case .overlapParams: "OverlapParams"
        case .raycastResult: "RaycastResult"
        case .tween: "Instance"
        case .track: "Instance"
        }
    }

    static let allTypeNames = ["Instance", "Vector3", "Vector2", "CFrame", "Color3", "BrickColor", "UDim", "UDim2", "Ray", "Rect",
                               "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "ColorSequence", "ColorSequenceKeypoint",
                               "Vector3int16", "Region3", "PhysicalProperties", "Font", "Faces", "Axes", "TweenInfo", "Random",
                               "Enums", "Enum", "EnumItem", "RBXScriptSignal", "RBXScriptConnection", "RaycastParams",
                               "OverlapParams", "RaycastResult"]
}

struct Region3: Hashable { var min: Vector3; var max: Vector3 }

/// Enum item value (port of lua/EnumItemV.kt).
struct EnumItem: Hashable {
    let enumType: String
    let name: String
    let value: Int
}

/// Strong reference into the Lua registry (functions, tables, threads kept alive from Swift).
public final class LuaRef {
    weak var rt: ScriptRuntime?
    let ref: Int32
    init(rt: ScriptRuntime, ref: Int32) { self.rt = rt; self.ref = ref }
    deinit { if let rt, let L = rt.mainState, rt.alive { lua_unref(L, ref) } }
    func push(_ L: LState) { lua_rawgeti(L, luau_swift_registryindex(), ref) }
}

let kUserdataTag: Int32 = 1

/// C-callable entry point for every Swift function exposed to Lua.
let scriptDispatch: luau_swift_dispatch_fn = { L, id, raise in
    guard let L, let ud = lua_callbacks(L).pointee.userdata else { return 0 }
    let rt = Unmanaged<ScriptRuntime>.fromOpaque(ud).takeUnretainedValue()
    let call = LuaCall(L: L, rt: rt)
    do {
        return try rt.functions[Int(id)](call)
    } catch let e as LuaError {
        luaL_where(L, 1)
        call.push(e.message)
        lua_concat(L, 2)
        raise?.pointee = 1
        return 0
    } catch {
        call.push("\(error)")
        raise?.pointee = 1
        return 0
    }
}

/// Releases the Swift box when Lua collects a userdata.
let boxDestructor: lua_Destructor = { _, p in
    guard let p else { return }
    let slot = p.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let raw = slot.pointee {
        Unmanaged<ObjBox>.fromOpaque(raw).release()
        slot.pointee = nil
    }
}

/// Typed view of the Lua stack during a Swift call (stack indices are 1-based arguments).
struct LuaCall {
    let L: LState
    unowned let rt: ScriptRuntime

    var top: Int32 { lua_gettop(L) }
    var count: Int { Int(lua_gettop(L)) }

    func type(_ i: Int32) -> Int32 { lua_type(L, i) }
    func isNil(_ i: Int32) -> Bool { lua_type(L, i) <= 0 }
    func isNumber(_ i: Int32) -> Bool { lua_type(L, i) == Int32(LUA_TNUMBER.rawValue) }
    func isString(_ i: Int32) -> Bool { lua_type(L, i) == Int32(LUA_TSTRING.rawValue) }
    func isBool(_ i: Int32) -> Bool { lua_type(L, i) == Int32(LUA_TBOOLEAN.rawValue) }
    func isFunction(_ i: Int32) -> Bool { lua_type(L, i) == Int32(LUA_TFUNCTION.rawValue) }
    func isTable(_ i: Int32) -> Bool { lua_type(L, i) == Int32(LUA_TTABLE.rawValue) }
    func isThread(_ i: Int32) -> Bool { lua_type(L, i) == Int32(LUA_TTHREAD.rawValue) }
    func typeName(_ i: Int32) -> String { rt.typeOf(L, i) }

    // MARK: readers

    func object(_ i: Int32) -> ScriptObject? { ScriptRuntime.box(L, i)?.obj }

    func string(_ i: Int32) -> String? {
        let t = lua_type(L, i)
        guard t == Int32(LUA_TSTRING.rawValue) || t == Int32(LUA_TNUMBER.rawValue) else { return nil }
        var len = 0
        guard let p = lua_tolstring(L, i, &len) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }
    func number(_ i: Int32) -> Double? {
        var ok: Int32 = 0
        let v = lua_tonumberx(L, i, &ok)
        return ok != 0 ? v : nil
    }
    func bool(_ i: Int32) -> Bool { lua_toboolean(L, i) != 0 }

    func checkString(_ i: Int32, _ fn: String = "") throws -> String {
        guard let s = string(i) else { throw argError(i, "string", fn) }
        return s
    }
    func checkNumber(_ i: Int32, _ fn: String = "") throws -> Double {
        guard let n = number(i) else { throw argError(i, "number", fn) }
        return n
    }
    func checkFloat(_ i: Int32, _ fn: String = "") throws -> Float { Float(try checkNumber(i, fn)) }
    func optNumber(_ i: Int32, _ def: Double) -> Double { isNil(i) ? def : (number(i) ?? def) }
    func optFloat(_ i: Int32, _ def: Float) -> Float { Float(optNumber(i, Double(def))) }
    func optString(_ i: Int32) -> String? { isNil(i) ? nil : string(i) }

    func instance(_ i: Int32) -> Instance? { if case .instance(let x)? = object(i) { return x }; return nil }
    func checkInstance(_ i: Int32, _ fn: String = "") throws -> Instance {
        guard let x = instance(i) else { throw argError(i, "Instance", fn) }
        return x
    }
    func vector3(_ i: Int32) -> Vector3? { if case .vector3(let x)? = object(i) { return x }; return nil }
    func checkVector3(_ i: Int32, _ fn: String = "") throws -> Vector3 {
        guard let x = vector3(i) else { throw argError(i, "Vector3", fn) }
        return x
    }
    func vector2(_ i: Int32) -> Vector2? { if case .vector2(let x)? = object(i) { return x }; return nil }
    func cframe(_ i: Int32) -> CFrame? { if case .cframe(let x)? = object(i) { return x }; return nil }
    func checkCFrame(_ i: Int32, _ fn: String = "") throws -> CFrame {
        guard let x = cframe(i) else { throw argError(i, "CFrame", fn) }
        return x
    }
    func color3(_ i: Int32) -> Color3? { if case .color3(let x)? = object(i) { return x }; return nil }
    func udim2(_ i: Int32) -> UDim2? { if case .udim2(let x)? = object(i) { return x }; return nil }
    func udim(_ i: Int32) -> UDim? { if case .udim(let x)? = object(i) { return x }; return nil }
    func enumItem(_ i: Int32) -> EnumItem? { if case .enumItem(let x)? = object(i) { return x }; return nil }

    func argError(_ i: Int32, _ expected: String, _ fn: String) -> LuaError {
        let got = isNil(i) ? "nil" : typeName(i)
        let what = fn.isEmpty ? "" : " to '\(fn)'"
        return LuaError("invalid argument #\(i)\(what) (\(expected) expected, got \(got))")
    }

    /// Keep a reference to the value at `i` (function/table/anything) alive from Swift.
    func ref(_ i: Int32) -> LuaRef {
        lua_pushvalue(L, i)
        let r = lua_ref(L, -1)
        lua_settop(L, -2)
        return LuaRef(rt: rt, ref: r)
    }

    // MARK: writers

    func pushNil() { lua_pushnil(L) }
    func push(_ b: Bool) { lua_pushboolean(L, b ? 1 : 0) }
    func push(_ n: Double) { lua_pushnumber(L, n) }
    func push(_ n: Float) { lua_pushnumber(L, Double(n)) }
    func push(_ n: Int) { lua_pushnumber(L, Double(n)) }
    func push(_ s: String) { ScriptRuntime.pushString(L, s) }
    func push(_ o: ScriptObject) { rt.pushObject(L, o) }
    func push(_ i: Instance?) { if let i { rt.pushInstance(L, i) } else { lua_pushnil(L) } }
    func push(_ v: Vector3) { push(.vector3(v)) }
    func push(_ c: CFrame) { push(.cframe(c)) }
    func push(_ r: LuaRef?) { if let r { r.push(L) } else { lua_pushnil(L) } }
    func push(_ v: ScriptValue) { rt.pushValue(L, v) }
    func pushFn(_ name: String, _ fn: @escaping ScriptFn) { rt.pushFunction(L, name, fn) }

    /// Push an array of values as a new Lua table.
    func pushArray<T>(_ items: [T], _ each: (T) -> Void) {
        lua_createtable(L, Int32(items.count), 0)
        for (k, it) in items.enumerated() {
            each(it)
            lua_rawseti(L, -2, Int32(k + 1))
        }
    }

    func yield(_ n: Int32 = 0) -> Int32 { lua_yield(L, n) }
    var isYieldable: Bool { lua_isyieldable(L) != 0 }
}

/// Plain Lua values converted to Swift (used for tables, attributes, JSON, DataStores, remotes).
indirect enum ScriptValue {
    case nil_
    case bool(Bool)
    case number(Double)
    case string(String)
    case object(ScriptObject)
    case table([(ScriptValue, ScriptValue)])
    case function(LuaRef)
    case opaque(LuaRef)

    var isNil: Bool { if case .nil_ = self { return true }; return false }
}

/// Public, minimal view of a Lua call for host-provided functions.
public struct ScriptCall {
    let c: LuaCall
    init(_ c: LuaCall) { self.c = c }
    public var count: Int { c.count }
    public func bool(_ i: Int32) -> Bool { c.bool(i) }
    public func number(_ i: Int32) -> Double? { c.number(i) }
    public func string(_ i: Int32) -> String? { c.string(i) }
    public func push(_ b: Bool) -> Int32 { c.push(b); return 1 }
    public func push(_ n: Double) -> Int32 { c.push(n); return 1 }
    public func push(_ v: Vector3) -> Int32 { c.push(v); return 1 }
    public func push(_ s: String) -> Int32 { c.push(s); return 1 }
}
