import Foundation
import Luau
import StudioCore

/// HttpService JSON (port of lua/Json.kt).
enum JSON {
    static func encode(_ v: ScriptValue) throws -> String {
        var out = ""
        try write(v, &out, depth: 0)
        return out
    }

    private static func write(_ v: ScriptValue, _ out: inout String, depth: Int) throws {
        guard depth < 64 else { throw LuaError("Can't convert to JSON: nesting too deep") }
        switch v {
        case .nil_: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            guard n.isFinite else { out += "null"; return }
            out += n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): out += quote(s)
        case .table(let kv):
            // Arrays: keys exactly 1...n
            let numeric = kv.compactMap { k, _ -> Int? in if case .number(let n) = k, n == n.rounded(), n >= 1 { return Int(n) }; return nil }
            if !kv.isEmpty && numeric.count == kv.count && Set(numeric) == Set(1...kv.count) {
                let sorted = kv.sorted { a, b in
                    if case .number(let x) = a.0, case .number(let y) = b.0 { return x < y }
                    return false
                }
                out += "["
                for (i, e) in sorted.enumerated() { if i > 0 { out += "," }; try write(e.1, &out, depth: depth + 1) }
                out += "]"
            } else if kv.isEmpty {
                out += "[]"
            } else {
                out += "{"
                var first = true
                for (k, val) in kv {
                    let ks: String
                    switch k {
                    case .string(let s): ks = s
                    case .number(let n): ks = n == n.rounded() ? String(Int64(n)) : String(n)
                    default: throw LuaError("Can't convert to JSON: invalid key type")
                    }
                    if !first { out += "," }
                    first = false
                    out += quote(ks) + ":"
                    try write(val, &out, depth: depth + 1)
                }
                out += "}"
            }
        case .object(let o): out += quote(DataTypes.describe(o))
        case .function, .opaque: throw LuaError("Can't convert to JSON: unsupported value")
        }
    }

    private static func quote(_ s: String) -> String {
        var r = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if ch.value < 0x20 { r += String(format: "\\u%04x", ch.value) } else { r.unicodeScalars.append(ch) }
            }
        }
        return r + "\""
    }

    static func decode(_ s: String) throws -> ScriptValue {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw LuaError("Can't parse JSON")
        }
        return convert(obj)
    }

    private static func convert(_ o: Any) -> ScriptValue {
        switch o {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .table(a.enumerated().map { (.number(Double($0.offset + 1)), convert($0.element)) })
        case let d as [String: Any]: return .table(d.map { (.string($0.key), convert($0.value)) })
        default: return .nil_
        }
    }
}

/// HttpService requests: the calling script yields until the response arrives.
enum HttpRequests {
    static func perform(_ c: LuaCall, _ m: String) throws -> Int32 {
        let rt = c.rt
        var req: URLRequest
        var raw = false
        if m == "RequestAsync" {
            guard case .table(let kv) = rt.readValue(c.L, 2) else { throw c.argError(2, "table", m) }
            func field(_ k: String) -> ScriptValue? { kv.first { if case .string(k) = $0.0 { return true }; return false }?.1 }
            guard case .string(let u)? = field("Url"), let url = URL(string: u) else { throw LuaError("Url is required") }
            req = URLRequest(url: url)
            if case .string(let method)? = field("Method") { req.httpMethod = method }
            if case .string(let body)? = field("Body") { req.httpBody = Data(body.utf8) }
            if case .table(let hs)? = field("Headers") {
                for (k, v) in hs { if case .string(let ks) = k, case .string(let vs) = v { req.setValue(vs, forHTTPHeaderField: ks) } }
            }
            raw = true
        } else {
            guard let url = URL(string: try c.checkString(2, m)) else { throw LuaError("Invalid URL") }
            req = URLRequest(url: url)
            if m == "PostAsync" {
                req.httpMethod = "POST"
                req.httpBody = Data((try c.checkString(3, m)).utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        guard let me = rt.currentThread(c.L) else { throw LuaError("HttpService requests must be made from a yieldable thread") }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let http = resp as? HTTPURLResponse
                let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if raw {
                    let result: ScriptValue = .table([
                        (.string("Success"), .bool(err == nil && (200..<300).contains(http?.statusCode ?? 0))),
                        (.string("StatusCode"), .number(Double(http?.statusCode ?? 0))),
                        (.string("StatusMessage"), .string(err?.localizedDescription ?? HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0))),
                        (.string("Body"), .string(body)),
                        (.string("Headers"), .table((http?.allHeaderFields ?? [:]).map { (.string("\($0.key)"), .string("\($0.value)")) })),
                    ])
                    rt.resume(me) { L in rt.pushValue(L, result); return 1 }
                } else if let err {
                    ScriptRuntime.pushString(me.co, "HttpError: \(err.localizedDescription)")
                    lua_resumeerror(me.co, nil)
                } else if let code = http?.statusCode, !(200..<300).contains(code) {
                    ScriptRuntime.pushString(me.co, "HTTP \(code)")
                    lua_resumeerror(me.co, nil)
                } else {
                    rt.resume(me) { L in ScriptRuntime.pushString(L, body); return 1 }
                }
            }
        }.resume()
        return c.yield(0)
    }
}

/// Straight-line pathfinding with ground snapping (PathfindingService stand-in).
enum Pathfinding {
    private static var store: [ObjectIdentifier: [Vector3]] = [:]
    static func compute(_ path: Instance, from a: Vector3, to b: Vector3) {
        let steps = max(1, Int((b - a).magnitude / 4))
        store[ObjectIdentifier(path)] = (0...steps).map { a.lerp(b, Float($0) / Float(steps)) }
        path.set("Status", .enumValue(EnumValue(0)), notify: false)
    }
    static func waypoints(_ path: Instance) -> [Vector3] { store[ObjectIdentifier(path)] ?? [] }
}

/// Shared physics knowledge that doesn't need a running simulation.
enum Physics {
    static var groups: Set<String> = ["Default"]
    private static var nonCollidable: Set<String> = []
    private static func key(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }
    static func setCollidable(_ a: String, _ b: String, _ on: Bool) {
        if on { nonCollidable.remove(key(a, b)) } else { nonCollidable.insert(key(a, b)) }
    }
    static func collidable(_ a: String, _ b: String) -> Bool { !nonCollidable.contains(key(a, b)) }

    /// Part mass from volume and density (Roblox: density * volume).
    static func mass(_ p: Instance) -> Float {
        if p.get("Massless")?.asBool == true { return 0 }
        let s = PartData.size(p)
        var volume = s.x * s.y * s.z
        switch PartData.shape(p) {
        case .ball: volume *= 0.5236
        case .cylinder: volume *= 0.7854
        case .wedge: volume *= 0.5
        case .cornerWedge: volume *= 0.3333
        case .block: break
        }
        var density = PhysicsMaterials.props(PartData.material(p)).0
        if case .physicalProps(let pp)? = p.get("CustomPhysicalProperties"), pp.isCustom { density = pp.density }
        return density * volume
    }
}

/// Model pivot math (InstanceApi.modelPivot / PivotTo).
enum ModelMath {
    static func parts(_ m: Instance) -> [Instance] { m.descendants().filter { $0.isA("BasePart") } }

    static func pivot(_ m: Instance) -> CFrame {
        if m.isA("BasePart") { return PartData.cframe(m) * (m.get("PivotOffset")?.asCFrame ?? .identity) }
        if case .optionalCFrame(let o)? = m.get("WorldPivotData"), let cf = o.value { return cf }
        if let pp = m.get("PrimaryPart")?.asInstance { return PartData.cframe(pp) }
        return boundingBox(m).0
    }

    static func pivotTo(_ m: Instance, _ target: CFrame) {
        let cur = pivot(m)
        let delta = target * cur.inverse
        if m.isA("BasePart") {
            PartData.setCFrame(m, delta * PartData.cframe(m))
            for d in m.descendants() where d.isA("BasePart") { PartData.setCFrame(d, delta * PartData.cframe(d)) }
            return
        }
        for p in parts(m) { PartData.setCFrame(p, delta * PartData.cframe(p)) }
        if case .optionalCFrame(let o)? = m.get("WorldPivotData"), o.value != nil {
            m.set("WorldPivotData", .optionalCFrame(OptionalCFrame(target)))
        }
    }

    /// (orientation, size) of the axis-aligned bounds (oriented by PrimaryPart when set).
    static func boundingBox(_ m: Instance) -> (CFrame, Vector3) {
        let ps = parts(m)
        guard !ps.isEmpty else { return (.identity, .zero) }
        let basis = (m.get("PrimaryPart")?.asInstance).map { PartData.cframe($0).rotationOnly } ?? .identity
        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
        for p in ps {
            let cf = basis.inverse * PartData.cframe(p), h = PartData.size(p) * 0.5
            for sx: Float in [-1, 1] { for sy: Float in [-1, 1] { for sz: Float in [-1, 1] {
                let c = cf * Vector3(h.x * sx, h.y * sy, h.z * sz)
                lo = lo.min(c); hi = hi.max(c)
            } } }
        }
        return (basis * CFrame.at((lo + hi) * 0.5), hi - lo)
    }
}

/// Absolute GUI layout (Instance absX/absY/absW/absH in the Android app).
enum Gui {
    static var viewport = Vector2(1280, 720)

    static func abs(_ g: Instance) -> (x: Float, y: Float, w: Float, h: Float) {
        if let r = rects[ObjectIdentifier(g)] { return r }
        guard g.isA("GuiObject"), let parent = g.parent else { return (0, 0, viewport.x, viewport.y) }
        let p = abs(parent)
        let size = g.get("Size").flatMap { if case .udim2(let u) = $0 { return u }; return nil } ?? UDim2(0, 100, 0, 100)
        let pos = g.get("Position").flatMap { if case .udim2(let u) = $0 { return u }; return nil } ?? UDim2(0, 0, 0, 0)
        let anchor = g.get("AnchorPoint").flatMap { if case .vector2(let v) = $0 { return v }; return nil } ?? .zero
        let w = size.x.scale * p.w + Float(size.x.offset), h = size.y.scale * p.h + Float(size.y.offset)
        let x = p.x + pos.x.scale * p.w + Float(pos.x.offset) - anchor.x * w
        let y = p.y + pos.y.scale * p.h + Float(pos.y.offset) - anchor.y * h
        return (x, y, w, h)
    }
}
