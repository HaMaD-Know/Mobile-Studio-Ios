import Foundation

// Value types ported from model/Vector3.kt, Vector2.kt, CFrame.kt, Color3.kt.

public struct Vector2: Hashable, CustomStringConvertible {
    public var x: Float, y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
    public static let zero = Vector2(0, 0)
    public static func + (a: Vector2, b: Vector2) -> Vector2 { Vector2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vector2, b: Vector2) -> Vector2 { Vector2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vector2, s: Float) -> Vector2 { Vector2(a.x * s, a.y * s) }
    public var magnitude: Float { (x * x + y * y).squareRoot() }
    public var description: String { "\(fmt(x)), \(fmt(y))" }
}

public struct Vector3: Hashable, CustomStringConvertible {
    public var x: Float, y: Float, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }

    public static let zero = Vector3(0, 0, 0)
    public static let one = Vector3(1, 1, 1)
    public static let xAxis = Vector3(1, 0, 0)
    public static let yAxis = Vector3(0, 1, 0)
    public static let zAxis = Vector3(0, 0, 1)
    public static func axis(_ i: Int) -> Vector3 { i == 0 ? xAxis : (i == 1 ? yAxis : zAxis) }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vector3, s: Float) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }
    public static func * (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x * b.x, a.y * b.y, a.z * b.z) }
    public static func / (a: Vector3, s: Float) -> Vector3 { Vector3(a.x / s, a.y / s, a.z / s) }
    public static func / (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x / b.x, a.y / b.y, a.z / b.z) }
    public static prefix func - (a: Vector3) -> Vector3 { Vector3(-a.x, -a.y, -a.z) }
    public static func += (a: inout Vector3, b: Vector3) { a = a + b }
    public static func -= (a: inout Vector3, b: Vector3) { a = a - b }

    public func dot(_ o: Vector3) -> Float { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var magnitude: Float { (x * x + y * y + z * z).squareRoot() }
    public var unit: Vector3 { let m = magnitude; return m < 1e-9 ? .zero : self / m }
    public func lerp(_ o: Vector3, _ t: Float) -> Vector3 { self + (o - self) * t }
    public var abs: Vector3 { Vector3(Swift.abs(x), Swift.abs(y), Swift.abs(z)) }
    public func min(_ o: Vector3) -> Vector3 { Vector3(Swift.min(x, o.x), Swift.min(y, o.y), Swift.min(z, o.z)) }
    public func max(_ o: Vector3) -> Vector3 { Vector3(Swift.max(x, o.x), Swift.max(y, o.y), Swift.max(z, o.z)) }
    public subscript(i: Int) -> Float {
        get { i == 0 ? x : (i == 1 ? y : z) }
        set { if i == 0 { x = newValue } else if i == 1 { y = newValue } else { z = newValue } }
    }
    public var description: String { "\(fmt(x)), \(fmt(y)), \(fmt(z))" }
}

/// Rigid transform: position + row-major 3x3 rotation, exactly like Roblox's CFrame.
public struct CFrame: Hashable, CustomStringConvertible {
    public var x: Float, y: Float, z: Float
    public var r00: Float, r01: Float, r02: Float
    public var r10: Float, r11: Float, r12: Float
    public var r20: Float, r21: Float, r22: Float

    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0,
                _ r00: Float = 1, _ r01: Float = 0, _ r02: Float = 0,
                _ r10: Float = 0, _ r11: Float = 1, _ r12: Float = 0,
                _ r20: Float = 0, _ r21: Float = 0, _ r22: Float = 1) {
        self.x = x; self.y = y; self.z = z
        self.r00 = r00; self.r01 = r01; self.r02 = r02
        self.r10 = r10; self.r11 = r11; self.r12 = r12
        self.r20 = r20; self.r21 = r21; self.r22 = r22
    }

    public static let identity = CFrame()
    public static func at(_ p: Vector3) -> CFrame { CFrame(p.x, p.y, p.z) }

    public var position: Vector3 { Vector3(x, y, z) }
    public var rightVector: Vector3 { Vector3(r00, r10, r20) }
    public var upVector: Vector3 { Vector3(r01, r11, r21) }
    public var backVector: Vector3 { Vector3(r02, r12, r22) }
    public var lookVector: Vector3 { Vector3(-r02, -r12, -r22) }
    public func column(_ i: Int) -> Vector3 { i == 0 ? rightVector : (i == 1 ? upVector : backVector) }

    public static func * (a: CFrame, o: CFrame) -> CFrame {
        let p = a * o.position
        return CFrame(p.x, p.y, p.z,
            a.r00 * o.r00 + a.r01 * o.r10 + a.r02 * o.r20,
            a.r00 * o.r01 + a.r01 * o.r11 + a.r02 * o.r21,
            a.r00 * o.r02 + a.r01 * o.r12 + a.r02 * o.r22,
            a.r10 * o.r00 + a.r11 * o.r10 + a.r12 * o.r20,
            a.r10 * o.r01 + a.r11 * o.r11 + a.r12 * o.r21,
            a.r10 * o.r02 + a.r11 * o.r12 + a.r12 * o.r22,
            a.r20 * o.r00 + a.r21 * o.r10 + a.r22 * o.r20,
            a.r20 * o.r01 + a.r21 * o.r11 + a.r22 * o.r21,
            a.r20 * o.r02 + a.r21 * o.r12 + a.r22 * o.r22)
    }
    public static func * (a: CFrame, v: Vector3) -> Vector3 { a.vectorToWorld(v) + a.position }
    public static func + (a: CFrame, v: Vector3) -> CFrame { a.withPosition(a.position + v) }
    public static func - (a: CFrame, v: Vector3) -> CFrame { a.withPosition(a.position - v) }

    public func vectorToWorld(_ v: Vector3) -> Vector3 {
        Vector3(r00 * v.x + r01 * v.y + r02 * v.z, r10 * v.x + r11 * v.y + r12 * v.z, r20 * v.x + r21 * v.y + r22 * v.z)
    }
    public func vectorToObject(_ v: Vector3) -> Vector3 {
        Vector3(r00 * v.x + r10 * v.y + r20 * v.z, r01 * v.x + r11 * v.y + r21 * v.z, r02 * v.x + r12 * v.y + r22 * v.z)
    }
    public func pointToObject(_ v: Vector3) -> Vector3 { vectorToObject(v - position) }
    public func pointToWorld(_ v: Vector3) -> Vector3 { self * v }
    public var inverse: CFrame {
        let p = vectorToObject(-position)
        return CFrame(p.x, p.y, p.z, r00, r10, r20, r01, r11, r21, r02, r12, r22)
    }
    public var rotationOnly: CFrame { withPosition(.zero) }
    public func withPosition(_ p: Vector3) -> CFrame {
        var c = self; c.x = p.x; c.y = p.y; c.z = p.z; return c
    }

    /// Euler angles in the order used by Roblox's `Orientation` property (degrees are applied by the caller).
    public var toOrientation: Vector3 {
        let rx = asin(Swift.min(1, Swift.max(-1, -r12)))
        if Swift.abs(r12) < 0.99999 {
            return Vector3(rx, atan2(r02, r22), atan2(r10, r11))
        }
        return Vector3(rx, atan2(-r20, r00), 0)
    }
    public var toEulerXYZ: Vector3 {
        let ry = asin(Swift.min(1, Swift.max(-1, r02)))
        if Swift.abs(r02) < 0.99999 {
            return Vector3(atan2(-r12, r22), ry, atan2(-r01, r00))
        }
        return Vector3(atan2(r21, r11), ry, 0)
    }

    public var components: [Float] { [x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22] }

    public static func fromColumns(_ p: Vector3, _ r: Vector3, _ u: Vector3, _ b: Vector3) -> CFrame {
        CFrame(p.x, p.y, p.z, r.x, u.x, b.x, r.y, u.y, b.y, r.z, u.z, b.z)
    }
    public static func rx(_ a: Float) -> CFrame { let c = cos(a), s = sin(a); return CFrame(0, 0, 0, 1, 0, 0, 0, c, -s, 0, s, c) }
    public static func ry(_ a: Float) -> CFrame { let c = cos(a), s = sin(a); return CFrame(0, 0, 0, c, 0, s, 0, 1, 0, -s, 0, c) }
    public static func rz(_ a: Float) -> CFrame { let c = cos(a), s = sin(a); return CFrame(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1) }
    public static func angles(_ x: Float, _ y: Float, _ z: Float) -> CFrame { rx(x) * ry(y) * rz(z) }
    public static func fromOrientation(_ x: Float, _ y: Float, _ z: Float) -> CFrame { ry(y) * rx(x) * rz(z) }
    public static func fromAxisAngle(_ axis: Vector3, _ angle: Float) -> CFrame {
        let a = axis.unit, h = angle / 2, s = sin(h)
        return fromQuaternion(.zero, a.x * s, a.y * s, a.z * s, cos(h))
    }
    public static func fromQuaternion(_ p: Vector3, _ qx: Float, _ qy: Float, _ qz: Float, _ qw: Float) -> CFrame {
        var n = (qx * qx + qy * qy + qz * qz + qw * qw).squareRoot()
        if n < 1e-9 { n = 1 }
        let x = qx / n, y = qy / n, z = qz / n, w = qw / n
        return CFrame(p.x, p.y, p.z,
            1 - (y * y + z * z) * 2, (x * y - z * w) * 2, (x * z + y * w) * 2,
            (x * y + z * w) * 2, 1 - (x * x + z * z) * 2, (y * z - x * w) * 2,
            (x * z - y * w) * 2, (y * z + x * w) * 2, 1 - 2 * (x * x + y * y))
    }
    public static func lookAt(_ eye: Vector3, _ target: Vector3, up: Vector3 = .yAxis) -> CFrame {
        let look = (target - eye).unit
        if look.magnitude < 1e-6 { return at(eye) }
        let back = -look
        var right = up.cross(back).unit
        if right.magnitude < 1e-6 { right = .xAxis }
        let u = back.cross(right).unit
        return fromColumns(eye, right, u, back)
    }
    /// Re-orthonormalise the rotation (Gram-Schmidt on right/up), keeping position.
    public var orthonormalized: CFrame {
        let r = rightVector.unit
        let u = (upVector - r * r.dot(upVector)).unit
        return CFrame.fromColumns(position, r, u, r.cross(u))
    }

    public var description: String { components.map(fmt).joined(separator: ", ") }
}

public struct Color3: Hashable, CustomStringConvertible {
    public var r: Float, g: Float, b: Float
    public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    public static func c8(_ f: Float) -> Int { Int((Swift.min(1, Swift.max(0, f)) * 255).rounded()) }
    public static func fromRGB(_ r: Int, _ g: Int, _ b: Int) -> Color3 { Color3(Float(r) / 255, Float(g) / 255, Float(b) / 255) }
    public static func fromHex(_ rgb: Int) -> Color3 { fromRGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255) }
    public static func fromHex(_ s: String) -> Color3? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return fromHex(v)
    }
    public var rgb8: (Int, Int, Int) { (Color3.c8(r), Color3.c8(g), Color3.c8(b)) }
    public var hex: String { let c = rgb8; return String(format: "#%02X%02X%02X", c.0, c.1, c.2) }
    public func lerp(_ o: Color3, _ t: Float) -> Color3 { Color3(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    public var description: String { let c = rgb8; return "[\(c.0), \(c.1), \(c.2)]" }
}

func fmt(_ f: Float) -> String {
    if f == f.rounded() && Swift.abs(f) < 1e9 { return String(Int(f)) }
    var s = String(format: "%.3f", f)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
