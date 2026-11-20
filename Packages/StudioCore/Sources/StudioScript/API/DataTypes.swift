import Foundation
import Luau
import StudioCore

// MARK: math helpers missing from the model types

extension Vector2 {
    func lerp(_ o: Vector2, _ t: Float) -> Vector2 { Vector2(x + (o.x - x) * t, y + (o.y - y) * t) }
    func dot(_ o: Vector2) -> Float { x * o.x + y * o.y }
    var unit: Vector2 { let m = magnitude; return m < 1e-9 ? .zero : Vector2(x / m, y / m) }
}

extension CFrame {
    /// (x, y, z, w) unit quaternion of the rotation.
    var quaternion: (Float, Float, Float, Float) {
        let trace = r00 + r11 + r22
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return ((r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s)
        } else if r00 > r11 && r00 > r22 {
            let s = (1 + r00 - r11 - r22).squareRoot() * 2
            return (0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s)
        } else if r11 > r22 {
            let s = (1 + r11 - r00 - r22).squareRoot() * 2
            return ((r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s)
        } else {
            let s = (1 + r22 - r00 - r11).squareRoot() * 2
            return ((r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s)
        }
    }

    /// Position lerp + rotation slerp (Roblox CFrame:Lerp).
    func lerp(_ o: CFrame, _ t: Float) -> CFrame {
        var (ax, ay, az, aw) = quaternion
        let (bx, by, bz, bw) = o.quaternion
        var d = ax * bx + ay * by + az * bz + aw * bw
        if d < 0 { ax = -ax; ay = -ay; az = -az; aw = -aw; d = -d }
        var s0 = 1 - t, s1 = t
        if d < 0.9995 {
            let th = acos(min(1, d)), sn = sin(th)
            s0 = sin((1 - t) * th) / sn; s1 = sin(t * th) / sn
        }
        let p = position.lerp(o.position, t)
        return CFrame.fromQuaternion(p, ax * s0 + bx * s1, ay * s0 + by * s1, az * s0 + bz * s1, aw * s0 + bw * s1)
    }

    var axisAngle: (Vector3, Float) {
        let (x, y, z, w) = quaternion
        let angle = 2 * acos(min(1, max(-1, w)))
        let s = (1 - w * w).squareRoot()
        if s < 1e-6 { return (.xAxis, 0) }
        return (Vector3(x / s, y / s, z / s), angle)
    }

    /// Euler angles for CFrame.fromEulerAnglesYXZ / ToEulerAnglesYXZ (same as Orientation order).
    var eulerYXZ: Vector3 { toOrientation }

    func fuzzyEq(_ o: CFrame, _ eps: Float = 1e-5) -> Bool {
        zip(components, o.components).allSatisfy { abs($0 - $1) <= eps }
    }
}

extension Color3 {
    var hsv: (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
    static func fromHSV(_ h: Float, _ s: Float, _ v: Float) -> Color3 {
        let hh = (h - floor(h)) * 6, i = Int(hh) % 6, f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return Color3(v, t, p)
        case 1: return Color3(q, v, p)
        case 2: return Color3(p, v, t)
        case 3: return Color3(p, q, v)
        case 4: return Color3(t, p, v)
        default: return Color3(v, p, q)
        }
    }
}

extension UDim2 {
    func lerp(_ o: UDim2, _ t: Float) -> UDim2 {
        UDim2(x.scale + (o.x.scale - x.scale) * t, Int32(Float(x.offset) + Float(o.x.offset - x.offset) * t),
              y.scale + (o.y.scale - y.scale) * t, Int32(Float(y.offset) + Float(o.y.offset - y.offset) * t))
    }
}

/// Roblox datatype libraries and member access (port of lua/LuaTypes.kt).
enum DataTypes {
    // MARK: describe / equality / arithmetic

    static func describe(_ o: ScriptObject) -> String {
        switch o {
        case .instance(let i): return i.name
        case .vector3(let v): return v.description
        case .vector2(let v): return v.description
        case .cframe(let c): return c.description
        case .color3(let c): return "\(fmt3(c.r)), \(fmt3(c.g)), \(fmt3(c.b))"
        case .brickColor(let n): return BrickColors.name(n)
        case .udim(let u): return u.description
        case .udim2(let u): return u.description
        case .ray(let r): return r.description
        case .rect(let r): return r.description
        case .numberRange(let r): return r.description
        case .numberSequence(let s): return s.description
        case .numberKey(let k): return "\(fmt3(k.time)) \(fmt3(k.value)) \(fmt3(k.envelope))"
        case .colorSequence(let s): return s.description
        case .colorKey(let k): return "\(fmt3(k.time)) \(describe(.color3(k.color)))"
        case .vector3int16(let v): return v.description
        case .region3(let r): return "\(describe(.cframe(.at((r.min + r.max) * 0.5)))); \(describe(.vector3(r.max - r.min)))"
        case .physicalProps(let p): return p.description
        case .font(let f): return "Font { Family = \(f.family), Weight = \(f.weight), Style = \(f.style == 1 ? "Italic" : "Normal") }"
        case .faces(let f): return f.description
        case .axes(let a): return a.description
        case .tweenInfo(let t): return "Time:\(t.time) DelayTime:\(t.delay) RepeatCount:\(t.repeatCount) Reverses:\(t.reverses) EasingDirection:\(ScriptEnums.item("EasingDirection", value: t.direction)?.name ?? "") EasingStyle:\(ScriptEnums.item("EasingStyle", value: t.style)?.name ?? "")"
        case .random: return "Random"
        case .enumLib: return "Enums"
        case .enumType(let t): return t
        case .enumItem(let e): return "Enum.\(e.enumType).\(e.name)"
        case .signal(let s): return "Signal \(s.name.replacingOccurrences(of: "Changed:", with: ""))"
        case .connection: return "Connection"
        case .raycastParams: return "RaycastParams"
        case .overlapParams: return "OverlapParams"
        case .raycastResult(let r): return "RaycastResult{\(r.instance.name) @ \(r.position); \(r.normal); \(Enums.itemName("Material", r.material) ?? "")}"
        case .tween: return "Tween"
        case .track: return "AnimationTrack"
        }
    }

    private static func fmt3(_ f: Float) -> String {
        if f == f.rounded() { return String(Int(f)) }
        return String(format: "%g", f)
    }

    static func equal(_ a: ScriptObject?, _ b: ScriptObject?) -> Bool {
        guard let a, let b else { return false }
        switch (a, b) {
        case (.instance(let x), .instance(let y)): return x === y
        case (.vector3(let x), .vector3(let y)): return x == y
        case (.vector2(let x), .vector2(let y)): return x == y
        case (.cframe(let x), .cframe(let y)): return x == y
        case (.color3(let x), .color3(let y)): return x == y
        case (.brickColor(let x), .brickColor(let y)): return x == y
        case (.udim(let x), .udim(let y)): return x == y
        case (.udim2(let x), .udim2(let y)): return x == y
        case (.ray(let x), .ray(let y)): return x == y
        case (.rect(let x), .rect(let y)): return x == y
        case (.numberRange(let x), .numberRange(let y)): return x == y
        case (.numberSequence(let x), .numberSequence(let y)): return x == y
        case (.colorSequence(let x), .colorSequence(let y)): return x == y
        case (.vector3int16(let x), .vector3int16(let y)): return x == y
        case (.enumItem(let x), .enumItem(let y)): return x == y
        case (.enumType(let x), .enumType(let y)): return x == y
        case (.tweenInfo(let x), .tweenInfo(let y)): return x == y
        case (.font(let x), .font(let y)): return x == y
        case (.random(let x), .random(let y)): return x === y
        case (.connection(let x), .connection(let y)): return x === y
        case (.signal(let x), .signal(let y)): return x.owner === y.owner && x.name == y.name
        case (.tween(let x), .tween(let y)): return x === y
        case (.track(let x), .track(let y)): return x === y
        case (.physicalProps(let x), .physicalProps(let y)): return x == y
        default: return false
        }
    }

    static func arith(_ c: LuaCall, _ op: String) throws -> Int32 {
        let a = c.object(1), b = c.object(2)
        let na = c.number(1).map(Float.init), nb = c.number(2).map(Float.init)
        func bad() -> LuaError { LuaError("attempt to perform arithmetic (\(op)) on \(c.typeName(1)) and \(c.typeName(2))") }
        switch (a, b, op) {
        case (.vector3(let x)?, _, "unm"): c.push(-x)
        case (.vector2(let x)?, _, "unm"): c.push(.vector2(Vector2(-x.x, -x.y)))
        case (.udim(let x)?, _, "unm"): c.push(.udim(UDim(-x.scale, -x.offset)))
        case (.udim2(let x)?, _, "unm"): c.push(.udim2(UDim2(-x.x.scale, -x.x.offset, -x.y.scale, -x.y.offset)))
        case (.vector3(let x)?, .vector3(let y)?, _):
            switch op {
            case "+": c.push(x + y)
            case "-": c.push(x - y)
            case "*": c.push(x * y)
            case "/": c.push(x / y)
            case "//": c.push(Vector3(floor(x.x / y.x), floor(x.y / y.y), floor(x.z / y.z)))
            default: throw bad()
            }
        case (.vector3(let x)?, nil, _):
            guard let s = nb else { throw bad() }
            switch op {
            case "*": c.push(x * s)
            case "/": c.push(x / s)
            case "//": c.push(Vector3(floor(x.x / s), floor(x.y / s), floor(x.z / s)))
            default: throw bad()
            }
        case (nil, .vector3(let y)?, _):
            guard let s = na else { throw bad() }
            switch op {
            case "*": c.push(y * s)
            case "/": c.push(Vector3(s / y.x, s / y.y, s / y.z))
            default: throw bad()
            }
        case (.vector2(let x)?, .vector2(let y)?, _):
            switch op {
            case "+": c.push(.vector2(x + y))
            case "-": c.push(.vector2(x - y))
            case "*": c.push(.vector2(Vector2(x.x * y.x, x.y * y.y)))
            case "/": c.push(.vector2(Vector2(x.x / y.x, x.y / y.y)))
            default: throw bad()
            }
        case (.vector2(let x)?, nil, _):
            guard let s = nb else { throw bad() }
            switch op {
            case "*": c.push(.vector2(x * s))
            case "/": c.push(.vector2(Vector2(x.x / s, x.y / s)))
            default: throw bad()
            }
        case (nil, .vector2(let y)?, "*"):
            guard let s = na else { throw bad() }
            c.push(.vector2(y * s))
        case (.cframe(let x)?, .cframe(let y)?, "*"): c.push(x * y)
        case (.cframe(let x)?, .vector3(let y)?, "*"): c.push(x * y)
        case (.cframe(let x)?, .vector3(let y)?, "+"): c.push(x + y)
        case (.cframe(let x)?, .vector3(let y)?, "-"): c.push(x - y)
        case (.udim(let x)?, .udim(let y)?, "+"): c.push(.udim(UDim(x.scale + y.scale, x.offset + y.offset)))
        case (.udim(let x)?, .udim(let y)?, "-"): c.push(.udim(UDim(x.scale - y.scale, x.offset - y.offset)))
        case (.udim2(let x)?, .udim2(let y)?, "+"):
            c.push(.udim2(UDim2(x.x.scale + y.x.scale, x.x.offset + y.x.offset, x.y.scale + y.y.scale, x.y.offset + y.y.offset)))
        case (.udim2(let x)?, .udim2(let y)?, "-"):
            c.push(.udim2(UDim2(x.x.scale - y.x.scale, x.x.offset - y.x.offset, x.y.scale - y.y.scale, x.y.offset - y.y.offset)))
        case (.vector3int16(let x)?, .vector3int16(let y)?, _):
            switch op {
            case "+": c.push(.vector3int16(Vector3int16(x.x &+ y.x, x.y &+ y.y, x.z &+ y.z)))
            case "-": c.push(.vector3int16(Vector3int16(x.x &- y.x, x.y &- y.y, x.z &- y.z)))
            default: throw bad()
            }
        default: throw bad()
        }
        return 1
    }

    static func compare(_ c: LuaCall, lessEqual: Bool) throws -> Int32 {
        throw LuaError("attempt to compare \(c.typeName(1)) \(lessEqual ? "<=" : "<") \(c.typeName(2))")
    }

    /// Interpolate tweenable values (LuaTypes.lerpValue).
    static func lerpValue(_ a: ScriptValue, _ b: ScriptValue, _ t: Float) -> ScriptValue? {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x + (y - x) * Double(t))
        case (.object(.vector3(let x)), .object(.vector3(let y))): return .object(.vector3(x.lerp(y, t)))
        case (.object(.vector2(let x)), .object(.vector2(let y))): return .object(.vector2(x.lerp(y, t)))
        case (.object(.cframe(let x)), .object(.cframe(let y))): return .object(.cframe(x.lerp(y, t)))
        case (.object(.color3(let x)), .object(.color3(let y))): return .object(.color3(x.lerp(y, t)))
        case (.object(.udim2(let x)), .object(.udim2(let y))): return .object(.udim2(x.lerp(y, t)))
        case (.object(.udim(let x)), .object(.udim(let y))):
            return .object(.udim(UDim(x.scale + (y.scale - x.scale) * t, Int32(Float(x.offset) + Float(y.offset - x.offset) * t))))
        case (.object(.numberRange(let x)), .object(.numberRange(let y))):
            return .object(.numberRange(NumberRange(x.min + (y.min - x.min) * t, x.max + (y.max - x.max) * t)))
        case (.object(.rect(let x)), .object(.rect(let y))):
            return .object(.rect(Rect(x.minX + (y.minX - x.minX) * t, x.minY + (y.minY - x.minY) * t,
                                      x.maxX + (y.maxX - x.maxX) * t, x.maxY + (y.maxY - x.maxY) * t)))
        default: return t >= 1 ? b : a
        }
    }

    // MARK: member access for non-Instance values

    static func index(_ c: LuaCall, _ o: ScriptObject, _ key: String) throws -> Int32? {
        func p(_ f: Float) -> Int32 { c.push(f); return 1 }
        func pv(_ v: Vector3) -> Int32 { c.push(v); return 1 }
        func method() -> Int32 { c.rt.pushMethod(c.L, typeName: o.typeName, key); return 1 }
        switch o {
        case .vector3(let v):
            switch key {
            case "X", "x": return p(v.x)
            case "Y", "y": return p(v.y)
            case "Z", "z": return p(v.z)
            case "Magnitude", "magnitude": return p(v.magnitude)
            case "Unit", "unit": return pv(v.unit)
            case "Lerp", "lerp", "Dot", "Cross", "FuzzyEq", "Min", "Max", "Abs", "Floor", "Ceil", "Sign", "Angle": return method()
            default: return nil
            }
        case .vector2(let v):
            switch key {
            case "X", "x": return p(v.x)
            case "Y", "y": return p(v.y)
            case "Magnitude", "magnitude": return p(v.magnitude)
            case "Unit", "unit": c.push(.vector2(v.unit)); return 1
            case "Lerp", "Dot", "Cross", "Min", "Max", "Abs", "Floor", "Ceil", "Sign", "Angle", "FuzzyEq": return method()
            default: return nil
            }
        case .cframe(let cf):
            switch key {
            case "Position", "p": return pv(cf.position)
            case "X", "x": return p(cf.x)
            case "Y", "y": return p(cf.y)
            case "Z", "z": return p(cf.z)
            case "LookVector", "lookVector": return pv(cf.lookVector)
            case "RightVector", "rightVector", "XVector": return pv(cf.rightVector)
            case "UpVector", "upVector", "YVector": return pv(cf.upVector)
            case "ZVector": return pv(cf.backVector)
            case "Rotation": c.push(cf.rotationOnly); return 1
            case "Inverse", "inverse", "Lerp", "lerp", "ToWorldSpace", "toWorldSpace", "ToObjectSpace", "toObjectSpace",
                 "PointToWorldSpace", "pointToWorldSpace", "PointToObjectSpace", "pointToObjectSpace", "VectorToWorldSpace",
                 "vectorToWorldSpace", "VectorToObjectSpace", "vectorToObjectSpace", "GetComponents", "components",
                 "ToEulerAnglesXYZ", "toEulerAnglesXYZ", "ToEulerAnglesYXZ", "toEulerAnglesYXZ", "ToOrientation", "toOrientation",
                 "ToAxisAngle", "toAxisAngle", "Orthonormalize", "FuzzyEq", "AngleBetween":
                return method()
            default: return nil
            }
        case .color3(let col):
            switch key {
            case "R", "r": return p(col.r)
            case "G", "g": return p(col.g)
            case "B", "b": return p(col.b)
            case "Lerp", "lerp", "ToHSV", "ToHex": return method()
            default: return nil
            }
        case .brickColor(let n):
            switch key {
            case "Name": c.push(BrickColors.name(n)); return 1
            case "Number": c.push(n); return 1
            case "Color": c.push(.color3(BrickColors.color(n))); return 1
            case "r": return p(BrickColors.color(n).r)
            case "g": return p(BrickColors.color(n).g)
            case "b": return p(BrickColors.color(n).b)
            default: return nil
            }
        case .udim(let u):
            switch key {
            case "Scale": return p(u.scale)
            case "Offset": c.push(Int(u.offset)); return 1
            default: return nil
            }
        case .udim2(let u):
            switch key {
            case "X", "Width": c.push(.udim(u.x)); return 1
            case "Y", "Height": c.push(.udim(u.y)); return 1
            case "Lerp": return method()
            default: return nil
            }
        case .ray(let r):
            switch key {
            case "Origin": return pv(r.origin)
            case "Direction": return pv(r.direction)
            case "Unit": c.push(.ray(Ray(r.origin, r.direction.unit))); return 1
            case "ClosestPoint", "Distance": return method()
            default: return nil
            }
        case .rect(let r):
            switch key {
            case "Min": c.push(.vector2(Vector2(r.minX, r.minY))); return 1
            case "Max": c.push(.vector2(Vector2(r.maxX, r.maxY))); return 1
            case "Width": return p(r.maxX - r.minX)
            case "Height": return p(r.maxY - r.minY)
            default: return nil
            }
        case .numberRange(let r):
            switch key { case "Min": return p(r.min); case "Max": return p(r.max); default: return nil }
        case .numberSequence(let s):
            guard key == "Keypoints" else { return nil }
            c.pushArray(s.keys) { c.push(.numberKey($0)) }
            return 1
        case .numberKey(let k):
            switch key { case "Time": return p(k.time); case "Value": return p(k.value); case "Envelope": return p(k.envelope); default: return nil }
        case .colorSequence(let s):
            guard key == "Keypoints" else { return nil }
            c.pushArray(s.keys) { c.push(.colorKey($0)) }
            return 1
        case .colorKey(let k):
            switch key { case "Time": return p(k.time); case "Value": c.push(.color3(k.color)); return 1; default: return nil }
        case .vector3int16(let v):
            switch key { case "X": c.push(Int(v.x)); return 1; case "Y": c.push(Int(v.y)); return 1; case "Z": c.push(Int(v.z)); return 1; default: return nil }
        case .region3(let r):
            switch key {
            case "CFrame": c.push(CFrame.at((r.min + r.max) * 0.5)); return 1
            case "Size": return pv(r.max - r.min)
            case "ExpandToGrid": return method()
            default: return nil
            }
        case .physicalProps(let pp):
            switch key {
            case "Density": return p(pp.density)
            case "Friction": return p(pp.friction)
            case "Elasticity": return p(pp.elasticity)
            case "FrictionWeight": return p(pp.frictionWeight)
            case "ElasticityWeight": return p(pp.elasticityWeight)
            case "AcousticAbsorption": return p(pp.acoustic)
            default: return nil
            }
        case .font(let f):
            switch key {
            case "Family": c.push(f.family); return 1
            case "Weight": c.push(.enumItem(ScriptEnums.item("FontWeight", value: f.weight) ?? EnumItem(enumType: "FontWeight", name: "Regular", value: 400))); return 1
            case "Style": c.push(.enumItem(ScriptEnums.item("FontStyle", value: f.style)!)); return 1
            case "Bold": c.push(f.weight >= 600); return 1
            default: return nil
            }
        case .faces(let f):
            let names = ["Right", "Top", "Back", "Left", "Bottom", "Front"]
            if let i = names.firstIndex(of: key) { c.push(f.bits & (1 << i) != 0); return 1 }
            return nil
        case .axes(let a):
            let names = ["X", "Y", "Z"]
            if let i = names.firstIndex(of: key) { c.push(a.bits & (1 << i) != 0); return 1 }
            return nil
        case .tweenInfo(let t):
            switch key {
            case "Time": return p(t.time)
            case "EasingStyle": c.push(.enumItem(ScriptEnums.item("EasingStyle", value: t.style)!)); return 1
            case "EasingDirection": c.push(.enumItem(ScriptEnums.item("EasingDirection", value: t.direction)!)); return 1
            case "RepeatCount": c.push(t.repeatCount); return 1
            case "Reverses": c.push(t.reverses); return 1
            case "DelayTime": return p(t.delay)
            default: return nil
            }
        case .random:
            switch key {
            case "NextNumber", "NextInteger", "NextUnitVector", "Shuffle", "Clone": return method()
            default: return nil
            }
        case .enumLib:
            if key == "GetEnums" { return method() }
            guard ScriptEnums.items(key) != nil else { throw LuaError("\(key) is not a valid member of \"Enum\"") }
            c.push(.enumType(key))
            return 1
        case .enumType(let t):
            if key == "GetEnumItems" || key == "FromName" || key == "FromValue" { return method() }
            guard let it = ScriptEnums.item(t, key) else { throw LuaError("\(key) is not a valid member of \"Enum.\(t)\"") }
            c.push(.enumItem(it))
            return 1
        case .enumItem(let e):
            switch key {
            case "Name": c.push(e.name); return 1
            case "Value": c.push(e.value); return 1
            case "EnumType": c.push(.enumType(e.enumType)); return 1
            case "IsA": return method()
            default: throw LuaError("\(key) is not a valid member of \"Enum.\(e.enumType).\(e.name)\"")
            }
        case .signal:
            switch key {
            case "Connect", "connect", "Once", "Wait", "wait", "ConnectParallel": return method()
            default: return nil
            }
        case .connection(let cn):
            switch key {
            case "Connected": c.push(cn.connected); return 1
            case "Disconnect", "disconnect": return method()
            default: return nil
            }
        case .raycastParams(let r):
            switch key {
            case "FilterDescendantsInstances": c.pushArray(r.filter) { c.push($0) }; return 1
            case "FilterType": c.push(.enumItem(ScriptEnums.item("RaycastFilterType", value: r.filterType)!)); return 1
            case "IgnoreWater": c.push(r.ignoreWater); return 1
            case "CollisionGroup": c.push(r.collisionGroup); return 1
            case "RespectCanCollide": c.push(r.respectCanCollide); return 1
            case "BruteForceAllSlow": c.push(r.bruteForceAllSlow); return 1
            case "AddToFilter": return method()
            default: return nil
            }
        case .overlapParams(let r):
            switch key {
            case "FilterDescendantsInstances": c.pushArray(r.filter) { c.push($0) }; return 1
            case "FilterType": c.push(.enumItem(ScriptEnums.item("RaycastFilterType", value: r.filterType)!)); return 1
            case "MaxParts": c.push(r.maxParts); return 1
            case "CollisionGroup": c.push(r.collisionGroup); return 1
            case "RespectCanCollide": c.push(r.respectCanCollide); return 1
            case "AddToFilter": return method()
            default: return nil
            }
        case .raycastResult(let r):
            switch key {
            case "Instance": c.push(r.instance); return 1
            case "Position": return pv(r.position)
            case "Normal": return pv(r.normal)
            case "Distance": return p(r.distance)
            case "Material": c.push(.enumItem(ScriptEnums.item("Material", value: r.material) ?? EnumItem(enumType: "Material", name: "Plastic", value: 256))); return 1
            default: return nil
            }
        case .instance, .tween, .track:
            return nil
        }
    }

    static func newIndex(_ c: LuaCall, _ o: ScriptObject, _ key: String) throws -> Bool {
        switch o {
        case .raycastParams(let r):
            switch key {
            case "FilterDescendantsInstances": r.filter = try instances(c, 3)
            case "FilterType": r.filterType = c.enumItem(3)?.value ?? Int(c.number(3) ?? 0)
            case "IgnoreWater": r.ignoreWater = c.bool(3)
            case "CollisionGroup": r.collisionGroup = c.string(3) ?? "Default"
            case "RespectCanCollide": r.respectCanCollide = c.bool(3)
            case "BruteForceAllSlow": r.bruteForceAllSlow = c.bool(3)
            default: return false
            }
            return true
        case .overlapParams(let r):
            switch key {
            case "FilterDescendantsInstances": r.filter = try instances(c, 3)
            case "FilterType": r.filterType = c.enumItem(3)?.value ?? Int(c.number(3) ?? 0)
            case "MaxParts": r.maxParts = Int(c.number(3) ?? 0)
            case "CollisionGroup": r.collisionGroup = c.string(3) ?? "Default"
            case "RespectCanCollide": r.respectCanCollide = c.bool(3)
            default: return false
            }
            return true
        default:
            return false
        }
    }

    /// Array of Instances from a Lua table argument.
    static func instances(_ c: LuaCall, _ i: Int32) throws -> [Instance] {
        if c.isNil(i) { return [] }
        guard c.isTable(i) else { throw c.argError(i, "table", "") }
        var out: [Instance] = []
        let n = lua_objlen(c.L, i)
        if n > 0 {
            for k in 1...n {
                lua_rawgeti(c.L, i, k)
                if let x = c.instance(-1) { out.append(x) }
                lua_settop(c.L, -2)
            }
        }
        return out
    }

    // MARK: methods

    static func call(_ c: LuaCall, _ o: ScriptObject, _ m: String) throws -> Int32? {
        switch o {
        case .vector3(let v):
            switch m {
            case "Lerp", "lerp": c.push(v.lerp(try c.checkVector3(2, m), try c.checkFloat(3, m)))
            case "Dot": c.push(v.dot(try c.checkVector3(2, m)))
            case "Cross": c.push(v.cross(try c.checkVector3(2, m)))
            case "FuzzyEq": c.push((v - (try c.checkVector3(2, m))).magnitude <= c.optFloat(3, 1e-5))
            case "Min": c.push(v.min(try c.checkVector3(2, m)))
            case "Max": c.push(v.max(try c.checkVector3(2, m)))
            case "Abs": c.push(v.abs)
            case "Floor": c.push(Vector3(floor(v.x), floor(v.y), floor(v.z)))
            case "Ceil": c.push(Vector3(ceil(v.x), ceil(v.y), ceil(v.z)))
            case "Sign": c.push(Vector3(sign(v.x), sign(v.y), sign(v.z)))
            case "Angle":
                let o2 = try c.checkVector3(2, m)
                let d = v.unit.dot(o2.unit)
                var a = acos(min(1, max(-1, d)))
                if let axis = c.vector3(3), v.cross(o2).dot(axis) < 0 { a = -a }
                c.push(a)
            default: return nil
            }
            return 1
        case .vector2(let v):
            switch m {
            case "Lerp": guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }; c.push(.vector2(v.lerp(o2, try c.checkFloat(3, m))))
            case "Dot": guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }; c.push(v.dot(o2))
            case "Cross": guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }; c.push(v.x * o2.y - v.y * o2.x)
            case "Min": guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }; c.push(.vector2(Vector2(min(v.x, o2.x), min(v.y, o2.y))))
            case "Max": guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }; c.push(.vector2(Vector2(max(v.x, o2.x), max(v.y, o2.y))))
            case "Abs": c.push(.vector2(Vector2(abs(v.x), abs(v.y))))
            case "Floor": c.push(.vector2(Vector2(floor(v.x), floor(v.y))))
            case "Ceil": c.push(.vector2(Vector2(ceil(v.x), ceil(v.y))))
            case "Sign": c.push(.vector2(Vector2(sign(v.x), sign(v.y))))
            case "Angle":
                guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }
                c.push(atan2(v.x * o2.y - v.y * o2.x, v.dot(o2)))
            case "FuzzyEq": guard let o2 = c.vector2(2) else { throw c.argError(2, "Vector2", m) }; c.push((v - o2).magnitude <= c.optFloat(3, 1e-5))
            default: return nil
            }
            return 1
        case .cframe(let cf):
            switch m {
            case "Inverse", "inverse": c.push(cf.inverse)
            case "Lerp", "lerp": c.push(cf.lerp(try c.checkCFrame(2, m), try c.checkFloat(3, m)))
            case "ToWorldSpace", "toWorldSpace":
                let n = max(1, c.top - 1)
                for k in 0..<n { c.push(cf * (c.cframe(2 + k) ?? .identity)) }
                return n
            case "ToObjectSpace", "toObjectSpace":
                let n = max(1, c.top - 1)
                for k in 0..<n { c.push(cf.inverse * (c.cframe(2 + k) ?? .identity)) }
                return n
            case "PointToWorldSpace", "pointToWorldSpace":
                let n = max(1, c.top - 1)
                for k in 0..<n { c.push(cf.pointToWorld(c.vector3(2 + k) ?? .zero)) }
                return n
            case "PointToObjectSpace", "pointToObjectSpace":
                let n = max(1, c.top - 1)
                for k in 0..<n { c.push(cf.pointToObject(c.vector3(2 + k) ?? .zero)) }
                return n
            case "VectorToWorldSpace", "vectorToWorldSpace":
                let n = max(1, c.top - 1)
                for k in 0..<n { c.push(cf.vectorToWorld(c.vector3(2 + k) ?? .zero)) }
                return n
            case "VectorToObjectSpace", "vectorToObjectSpace":
                let n = max(1, c.top - 1)
                for k in 0..<n { c.push(cf.vectorToObject(c.vector3(2 + k) ?? .zero)) }
                return n
            case "GetComponents", "components":
                for x in cf.components { c.push(x) }
                return 12
            case "ToEulerAnglesXYZ", "toEulerAnglesXYZ":
                let e = cf.toEulerXYZ; c.push(e.x); c.push(e.y); c.push(e.z); return 3
            case "ToEulerAnglesYXZ", "toEulerAnglesYXZ", "ToOrientation", "toOrientation":
                let e = cf.toOrientation; c.push(e.x); c.push(e.y); c.push(e.z); return 3
            case "ToAxisAngle", "toAxisAngle":
                let (axis, ang) = cf.axisAngle; c.push(axis); c.push(ang); return 2
            case "Orthonormalize": c.push(cf.orthonormalized)
            case "FuzzyEq": c.push(cf.fuzzyEq(try c.checkCFrame(2, m), c.optFloat(3, 1e-5)))
            case "AngleBetween":
                let o2 = try c.checkCFrame(2, m)
                c.push((cf.rotationOnly.inverse * o2.rotationOnly).axisAngle.1)
            default: return nil
            }
            return 1
        case .color3(let col):
            switch m {
            case "Lerp", "lerp": guard let o2 = c.color3(2) else { throw c.argError(2, "Color3", m) }; c.push(.color3(col.lerp(o2, try c.checkFloat(3, m))))
            case "ToHSV": let (h, s, v) = col.hsv; c.push(h); c.push(s); c.push(v); return 3
            case "ToHex": c.push(String(col.hex.dropFirst()))
            default: return nil
            }
            return 1
        case .udim2(let u):
            guard m == "Lerp", let o2 = c.udim2(2) else { return nil }
            c.push(.udim2(u.lerp(o2, try c.checkFloat(3, m))))
            return 1
        case .ray(let r):
            let p = try c.checkVector3(2, m)
            let d = r.direction.unit
            let t = max(0, (p - r.origin).dot(d))
            let closest = r.origin + d * t
            if m == "ClosestPoint" { c.push(closest) } else if m == "Distance" { c.push((p - closest).magnitude) } else { return nil }
            return 1
        case .region3(let r):
            guard m == "ExpandToGrid" else { return nil }
            let g = try c.checkFloat(2, m)
            let mn = Vector3(floor(r.min.x / g) * g, floor(r.min.y / g) * g, floor(r.min.z / g) * g)
            let mx = Vector3(ceil(r.max.x / g) * g, ceil(r.max.y / g) * g, ceil(r.max.z / g) * g)
            c.push(.region3(Region3(min: mn, max: mx)))
            return 1
        case .random(let rng):
            switch m {
            case "NextNumber":
                let lo = c.optNumber(2, 0), hi = c.optNumber(3, 1)
                c.push(lo + rng.nextNumber() * (hi - lo))
            case "NextInteger":
                c.push(rng.nextInteger(Int(try c.checkNumber(2, m)), Int(try c.checkNumber(3, m))))
            case "NextUnitVector":
                let z = Float(rng.nextNumber() * 2 - 1), a = Float(rng.nextNumber() * 2 * .pi), r = (1 - z * z).squareRoot()
                c.push(Vector3(r * cos(a), r * sin(a), z))
            case "Shuffle":
                guard c.isTable(2) else { throw c.argError(2, "table", m) }
                let n = Int(lua_objlen(c.L, 2))
                if n > 1 {
                    for i in stride(from: n, to: 1, by: -1) {
                        let j = rng.nextInteger(1, i)
                        lua_rawgeti(c.L, 2, Int32(i)); lua_rawgeti(c.L, 2, Int32(j))
                        lua_rawseti(c.L, 2, Int32(i)); lua_rawseti(c.L, 2, Int32(j))
                    }
                }
                return 0
            case "Clone": c.push(.random(rng.clone()))
            default: return nil
            }
            return 1
        case .enumLib:
            guard m == "GetEnums" else { return nil }
            c.pushArray(ScriptEnums.names) { c.push(.enumType($0)) }
            return 1
        case .enumType(let t):
            switch m {
            case "GetEnumItems":
                let items = (ScriptEnums.items(t) ?? []).map { EnumItem(enumType: t, name: $0.0, value: $0.1) }
                c.pushArray(items) { c.push(.enumItem($0)) }
            case "FromName":
                if let it = ScriptEnums.item(t, try c.checkString(2, m)) { c.push(.enumItem(it)) } else { c.pushNil() }
            case "FromValue":
                if let it = ScriptEnums.item(t, value: Int(try c.checkNumber(2, m))) { c.push(.enumItem(it)) } else { c.pushNil() }
            default: return nil
            }
            return 1
        case .enumItem(let e):
            guard m == "IsA" else { return nil }
            c.push(e.enumType == (try c.checkString(2, m)))
            return 1
        case .signal(let s):
            switch m {
            case "Connect", "connect", "ConnectParallel", "Once":
                guard c.isFunction(2) else { throw c.argError(2, "function", m) }
                let cn = c.rt.connect(s.owner, s.name, c.ref(2), once: m == "Once")
                c.push(.connection(cn))
                return 1
            case "Wait", "wait":
                return try c.rt.waitSignal(c, s.owner, s.name)
            default: return nil
            }
        case .connection(let cn):
            guard m == "Disconnect" || m == "disconnect" else { return nil }
            c.rt.disconnect(cn)
            return 0
        case .raycastParams(let r):
            guard m == "AddToFilter" else { return nil }
            if let i = c.instance(2) { r.filter.append(i) } else { r.filter += try instances(c, 2) }
            return 0
        case .overlapParams(let r):
            guard m == "AddToFilter" else { return nil }
            if let i = c.instance(2) { r.filter.append(i) } else { r.filter += try instances(c, 2) }
            return 0
        default:
            return nil
        }
    }

    // MARK: constructors (global libraries)

    static func install(_ rt: ScriptRuntime, _ L: LState) {
        func lib(_ name: String, _ body: () -> Void) {
            lua_createtable(L, 0, 8)
            body()
            lua_setreadonly(L, -1, 1)
            lua_setfield(L, luau_swift_globalsindex(), name)
        }
        func fn(_ name: String, _ f: @escaping ScriptFn) {
            rt.pushFunction(L, name, f)
            lua_rawsetfield(L, -2, name)
        }
        func val(_ name: String, _ o: ScriptObject) {
            rt.pushObject(L, o)
            lua_rawsetfield(L, -2, name)
        }

        lib("Vector3") {
            fn("new") { c in c.push(Vector3(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0))); return 1 }
            val("zero", .vector3(.zero)); val("one", .vector3(.one))
            val("xAxis", .vector3(.xAxis)); val("yAxis", .vector3(.yAxis)); val("zAxis", .vector3(.zAxis))
            fn("FromNormalId") { c in
                let v = c.enumItem(1)?.value ?? Int(c.number(1) ?? 0)
                let dirs: [Vector3] = [.xAxis, .yAxis, .zAxis, -Vector3.xAxis, -Vector3.yAxis, -Vector3.zAxis]
                c.push(dirs[max(0, min(5, v))]); return 1
            }
            fn("FromAxis") { c in c.push(Vector3.axis(max(0, min(2, c.enumItem(1)?.value ?? Int(c.number(1) ?? 0))))); return 1 }
        }
        lib("Vector2") {
            fn("new") { c in c.push(.vector2(Vector2(c.optFloat(1, 0), c.optFloat(2, 0)))); return 1 }
            val("zero", .vector2(.zero)); val("one", .vector2(Vector2(1, 1)))
            val("xAxis", .vector2(Vector2(1, 0))); val("yAxis", .vector2(Vector2(0, 1)))
        }
        lib("Vector3int16") {
            fn("new") { c in c.push(.vector3int16(Vector3int16(Int16(clamping: Int(c.optNumber(1, 0))), Int16(clamping: Int(c.optNumber(2, 0))), Int16(clamping: Int(c.optNumber(3, 0)))))); return 1 }
        }
        lib("CFrame") {
            fn("new") { c in
                let n = c.top
                if n == 0 { c.push(CFrame.identity); return 1 }
                if let p = c.vector3(1) {
                    if let look = c.vector3(2) { c.push(CFrame.lookAt(p, look)); return 1 }
                    c.push(CFrame.at(p)); return 1
                }
                if n >= 12 {
                    var f = [Float](); for i in 1...12 { f.append(try c.checkFloat(Int32(i), "CFrame.new")) }
                    c.push(CFrame(f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11])); return 1
                }
                if n >= 7 {
                    var f = [Float](); for i in 1...7 { f.append(try c.checkFloat(Int32(i), "CFrame.new")) }
                    c.push(CFrame.fromQuaternion(Vector3(f[0], f[1], f[2]), f[3], f[4], f[5], f[6])); return 1
                }
                c.push(CFrame.at(Vector3(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0)))); return 1
            }
            fn("lookAt") { c in c.push(CFrame.lookAt(try c.checkVector3(1), try c.checkVector3(2), up: c.vector3(3) ?? .yAxis)); return 1 }
            fn("lookAlong") { c in let p = try c.checkVector3(1); c.push(CFrame.lookAt(p, p + (try c.checkVector3(2)), up: c.vector3(3) ?? .yAxis)); return 1 }
            let xyz: ScriptFn = { c in c.push(CFrame.angles(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0))); return 1 }
            fn("Angles", xyz); fn("fromEulerAnglesXYZ", xyz)
            let yxz: ScriptFn = { c in c.push(CFrame.fromOrientation(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0))); return 1 }
            fn("fromEulerAnglesYXZ", yxz); fn("fromOrientation", yxz)
            fn("fromEulerAngles") { c in
                // Default order XYZ.
                c.push(CFrame.angles(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0))); return 1
            }
            fn("fromAxisAngle") { c in c.push(CFrame.fromAxisAngle(try c.checkVector3(1), try c.checkFloat(2))); return 1 }
            fn("fromMatrix") { c in
                let p = try c.checkVector3(1), r = try c.checkVector3(2), u = try c.checkVector3(3)
                let b = c.vector3(4) ?? r.cross(u).unit
                c.push(CFrame.fromColumns(p, r, u, b)); return 1
            }
            val("identity", .cframe(.identity))
        }
        lib("Color3") {
            fn("new") { c in c.push(.color3(Color3(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0)))); return 1 }
            fn("fromRGB") { c in c.push(.color3(Color3.fromRGB(Int(c.optNumber(1, 0)), Int(c.optNumber(2, 0)), Int(c.optNumber(3, 0))))); return 1 }
            fn("fromHSV") { c in c.push(.color3(Color3.fromHSV(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0)))); return 1 }
            fn("fromHex") { c in
                guard let col = Color3.fromHex(try c.checkString(1)) else { throw LuaError("Unable to convert characters to hex value") }
                c.push(.color3(col)); return 1
            }
            fn("toHSV") { c in
                guard let col = c.color3(1) else { throw c.argError(1, "Color3", "toHSV") }
                let (h, s, v) = col.hsv; c.push(h); c.push(s); c.push(v); return 3
            }
        }
        lib("BrickColor") {
            fn("new") { c in
                if let n = c.number(1), c.top < 3 { c.push(.brickColor(Int(n))); return 1 }
                if let s = c.string(1) { c.push(.brickColor(BrickColors.byName(s) ?? 194)); return 1 }
                if let col = c.color3(1) { c.push(.brickColor(BrickColors.closest(col))); return 1 }
                if c.top >= 3 { c.push(.brickColor(BrickColors.closest(Color3(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0))))); return 1 }
                c.push(.brickColor(194)); return 1
            }
            fn("random") { c in c.push(.brickColor(BrickColors.all.randomElement() ?? 194)); return 1 }
            fn("palette") { c in let all = BrickColors.all; c.push(.brickColor(all[max(0, min(all.count - 1, Int(c.optNumber(1, 0))))])); return 1 }
            for (n, name) in [(1, "White"), (194, "Gray"), (199, "DarkGray"), (26, "Black"), (21, "Red"), (24, "Yellow"), (28, "Green"), (23, "Blue")] {
                fn(name) { c in c.push(.brickColor(n)); return 1 }
            }
        }
        lib("UDim") {
            fn("new") { c in c.push(.udim(UDim(c.optFloat(1, 0), Int32(c.optNumber(2, 0))))); return 1 }
        }
        lib("UDim2") {
            fn("new") { c in
                if let a = c.udim(1), let b = c.udim(2) { c.push(.udim2(UDim2(a.scale, a.offset, b.scale, b.offset))); return 1 }
                c.push(.udim2(UDim2(c.optFloat(1, 0), Int32(c.optNumber(2, 0)), c.optFloat(3, 0), Int32(c.optNumber(4, 0))))); return 1
            }
            fn("fromScale") { c in c.push(.udim2(UDim2(c.optFloat(1, 0), 0, c.optFloat(2, 0), 0))); return 1 }
            fn("fromOffset") { c in c.push(.udim2(UDim2(0, Int32(c.optNumber(1, 0)), 0, Int32(c.optNumber(2, 0))))); return 1 }
        }
        lib("Ray") {
            fn("new") { c in c.push(.ray(Ray(c.vector3(1) ?? .zero, c.vector3(2) ?? .zero))); return 1 }
        }
        lib("Rect") {
            fn("new") { c in
                if let a = c.vector2(1), let b = c.vector2(2) { c.push(.rect(Rect(a.x, a.y, b.x, b.y))); return 1 }
                c.push(.rect(Rect(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0), c.optFloat(4, 0)))); return 1
            }
        }
        lib("Region3") {
            fn("new") { c in c.push(.region3(Region3(min: c.vector3(1) ?? .zero, max: c.vector3(2) ?? .zero))); return 1 }
        }
        lib("NumberRange") {
            fn("new") { c in let a = c.optFloat(1, 0); c.push(.numberRange(NumberRange(a, c.optFloat(2, a)))); return 1 }
        }
        lib("NumberSequenceKeypoint") {
            fn("new") { c in c.push(.numberKey(NumberKey(c.optFloat(1, 0), c.optFloat(2, 0), c.optFloat(3, 0)))); return 1 }
        }
        lib("NumberSequence") {
            fn("new") { c in
                if c.isTable(1) {
                    var keys: [NumberKey] = []
                    let n = lua_objlen(c.L, 1)
                    if n > 0 { for k in 1...n { lua_rawgeti(c.L, 1, k); if case .numberKey(let nk)? = c.object(-1) { keys.append(nk) }; lua_settop(c.L, -2) } }
                    c.push(.numberSequence(NumberSequence(keys))); return 1
                }
                let a = c.optFloat(1, 0), b = c.optFloat(2, a)
                c.push(.numberSequence(NumberSequence([NumberKey(0, a, 0), NumberKey(1, b, 0)]))); return 1
            }
        }
        lib("ColorSequenceKeypoint") {
            fn("new") { c in c.push(.colorKey(ColorKey(c.optFloat(1, 0), c.color3(2) ?? Color3(1, 1, 1), 0))); return 1 }
        }
        lib("ColorSequence") {
            fn("new") { c in
                if c.isTable(1) {
                    var keys: [ColorKey] = []
                    let n = lua_objlen(c.L, 1)
                    if n > 0 { for k in 1...n { lua_rawgeti(c.L, 1, k); if case .colorKey(let ck)? = c.object(-1) { keys.append(ck) }; lua_settop(c.L, -2) } }
                    c.push(.colorSequence(ColorSequence(keys))); return 1
                }
                let a = c.color3(1) ?? Color3(1, 1, 1), b = c.color3(2) ?? a
                c.push(.colorSequence(ColorSequence([ColorKey(0, a, 0), ColorKey(1, b, 0)]))); return 1
            }
        }
        lib("PhysicalProperties") {
            fn("new") { c in
                if let e = c.enumItem(1) {
                    let d = PhysicsMaterials.props(e.value)
                    c.push(.physicalProps(PhysicalProps(flags: 1, density: d.0, friction: d.1, elasticity: d.2, frictionWeight: 1, elasticityWeight: 1)))
                    return 1
                }
                c.push(.physicalProps(PhysicalProps(flags: 1, density: c.optFloat(1, 0.7), friction: c.optFloat(2, 0.3), elasticity: c.optFloat(3, 0.5),
                                                    frictionWeight: c.optFloat(4, 1), elasticityWeight: c.optFloat(5, 1))))
                return 1
            }
        }
        lib("Font") {
            fn("new") { c in
                let w = c.enumItem(2)?.value ?? 400, s = c.enumItem(3)?.value ?? 0
                c.push(.font(FontValue(try c.checkString(1), w, s, ""))); return 1
            }
            fn("fromName") { c in
                let w = c.enumItem(2)?.value ?? 400, s = c.enumItem(3)?.value ?? 0
                c.push(.font(FontValue("rbxasset://fonts/families/\(try c.checkString(1)).json", w, s, ""))); return 1
            }
            fn("fromEnum") { c in
                let name = c.enumItem(1)?.name ?? "SourceSans"
                let bold = name.hasSuffix("Bold")
                let fam = name.replacingOccurrences(of: "Bold", with: "").replacingOccurrences(of: "Italic", with: "")
                c.push(.font(FontValue("rbxasset://fonts/families/\(fam == "SourceSans" ? "SourceSansPro" : fam).json", bold ? 700 : 400, name.hasSuffix("Italic") ? 1 : 0, "")))
                return 1
            }
        }
        lib("TweenInfo") {
            fn("new") { c in
                var t = TweenInfoV()
                t.time = c.optFloat(1, 1)
                t.style = c.enumItem(2)?.value ?? 3
                t.direction = c.enumItem(3)?.value ?? 1
                t.repeatCount = Int(c.optNumber(4, 0))
                t.reverses = c.bool(5)
                t.delay = c.optFloat(6, 0)
                c.push(.tweenInfo(t)); return 1
            }
        }
        lib("Random") {
            fn("new") { c in
                let seed = c.number(1).map { UInt64(bitPattern: Int64($0)) } ?? UInt64(Date().timeIntervalSince1970 * 1000)
                c.push(.random(RandomGen(seed: seed))); return 1
            }
        }
        lib("Faces") {
            fn("new") { c in
                var bits: UInt8 = 0
                for i in 1...max(1, c.top) { if let e = c.enumItem(i), e.enumType == "NormalId" { bits |= 1 << UInt8(e.value) } }
                c.push(.faces(Faces(bits))); return 1
            }
        }
        lib("Axes") {
            fn("new") { c in
                var bits: UInt8 = 0
                for i in 1...max(1, c.top) { if let e = c.enumItem(i) { bits |= 1 << UInt8(e.value % 3) } }
                c.push(.axes(Axes(bits))); return 1
            }
        }
        lib("RaycastParams") { fn("new") { c in c.push(.raycastParams(RaycastParamsV())); return 1 } }
        lib("OverlapParams") { fn("new") { c in c.push(.overlapParams(OverlapParamsV())); return 1 } }

        rt.pushObject(L, .enumLib)
        lua_setfield(L, luau_swift_globalsindex(), "Enum")
    }
}

/// Default physical properties per material (density, friction, elasticity), Roblox values.
enum PhysicsMaterials {
    static func props(_ m: Int) -> (Float, Float, Float) {
        switch m {
        case 512, 528: return (0.35, 0.48, 0.2)       // Wood
        case 784: return (2.56, 0.2, 0.17)           // Marble
        case 788, 800, 832, 896: return (2.69, 0.4, 0.2)
        case 816, 836, 1376: return (2.4, 0.7, 0.2)  // Concrete / pavement / asphalt
        case 848, 880, 864: return (1.92, 0.8, 0.15) // Brick / cobblestone / pebble
        case 1040, 1056, 1088, 1072: return (7.85, 0.4, 0.25) // Metals
        case 1280, 1284: return (0.9, 0.4, 0.1)      // Grass
        case 1296: return (1.6, 0.5, 0.05)           // Sand
        case 1312: return (0.7, 0.35, 0.05)          // Fabric
        case 1328: return (0.9, 0.3, 0.03)           // Snow
        case 1344, 1360: return (0.9, 0.3, 0.07)
        case 1536, 1552: return (0.92, 0.02, 0.15)   // Ice
        case 1568: return (2.4, 0.25, 0.2)           // Glass
        case 2311: return (1.3, 1.0, 0.95)           // Rubber
        default: return (0.7, 0.3, 0.5)              // Plastic
        }
    }
}
