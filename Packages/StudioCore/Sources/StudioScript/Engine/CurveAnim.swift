import Foundation
import StudioCore

/// Decodes Roblox `CurveAnimation` / `FloatCurve` (`ValuesAndTimes` little-endian binary format)
/// into an `AnimClip` (port of engine/CurveAnim.kt).
public enum CurveAnim {
    public static let ticksPerSecond: Float = 2400

    public struct FKey: Equatable {
        public let t: Float
        public let v: Float
        public let interp: Int
        public let lt: Float
        public let rt: Float
        public init(t: Float, v: Float, interp: Int, lt: Float = 0, rt: Float = 0) {
            self.t = t; self.v = v; self.interp = interp; self.lt = lt; self.rt = rt
        }
    }

    private static let orders: [[Int]] = [
        [0, 1, 2], [0, 2, 1], [1, 2, 0], [1, 0, 2], [2, 0, 1], [2, 1, 0],
    ]

    public static func decode(_ data: Data) -> [FKey] {
        let b = [UInt8](data)
        guard b.count >= 16 else { return [] }
        func readI32(_ off: Int) -> Int32 {
            Int32(bitPattern: UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
        }
        func readF32(_ off: Int) -> Float {
            Float(bitPattern: UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
        }

        let count = Int(readI32(4))
        guard count > 0 && count <= 100_000 else { return [] }
        let rem = b.count - 16 - count * 4
        guard rem > 0 else { return [] }
        let stride = rem / count
        guard stride >= 5 && stride < 33 else { return [] }
        let timesOff = 8 + count * stride
        guard timesOff + 8 + count * 4 <= b.count else { return [] }

        var vals = [Float](repeating: 0, count: count)
        var interps = [Int](repeating: 0, count: count)
        var lts = [Float](repeating: 0, count: count)
        var rts = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let p = 8 + i * stride
            interps[i] = Int(b[p])
            let vp = p + (stride >= 6 ? 2 : 1)
            vals[i] = readF32(vp)
            if stride >= 14 {
                lts[i] = readF32(vp + 4)
                rts[i] = readF32(vp + 8)
            }
        }
        let tCount = Int(readI32(timesOff + 4))
        guard tCount == count else { return [] }
        var out: [FKey] = []
        out.reserveCapacity(count)
        let tBase = timesOff + 8
        for i in 0..<count {
            let ticks = readI32(tBase + i * 4)
            out.append(FKey(t: Float(ticks) / ticksPerSecond, v: vals[i], interp: interps[i], lt: lts[i], rt: rts[i]))
        }
        return out
    }

    public static func eval(_ keys: [FKey], _ t: Float) -> Float {
        guard let first = keys.first else { return 0 }
        if t <= first.t { return first.v }
        let last = keys[keys.count - 1]
        if t >= last.t { return last.v }
        var i = 0
        while i < keys.count - 2 && keys[i + 1].t <= t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let span = b.t - a.t
        if span <= 1e-6 { return b.v }
        let u = (t - a.t) / span
        switch a.interp {
        case 0: return a.v
        case 2:
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1
            let h10 = u3 - 2 * u2 + u
            let h01 = -2 * u3 + 3 * u2
            let h11 = u3 - u2
            return h00 * a.v + h10 * span * a.rt + h01 * b.v + h11 * span * b.lt
        default:
            return a.v + (b.v - a.v) * u
        }
    }

    private static func bytesOf(_ v: PropValue?) -> Data? {
        switch v {
        case .binaryString(let b)?: return b.bytes
        case .string(let s)?: return Data(s.utf8)
        default: return nil
        }
    }

    private static func channel(_ curve: Instance?, _ axis: String) -> [FKey] {
        guard let fc = curve?.findFirstChild(axis), fc.className == "FloatCurve",
              let raw = bytesOf(fc.get("ValuesAndTimes")) else { return [] }
        return decode(raw)
    }

    private static func rot(_ axis: Int, _ a: Float) -> CFrame {
        switch axis {
        case 0: return .rx(a)
        case 1: return .ry(a)
        default: return .rz(a)
        }
    }

    public static func from(_ anim: Instance) -> AnimClip? {
        guard anim.className == "CurveAnimation" else { return nil }
        var joints: [String: [AnimClip.Key]] = [:]
        var length: Float = 0

        func walk(_ node: Instance) {
            for child in node.children where child.className == "Folder" {
                let pos = child.children.first { $0.className == "Vector3Curve" }
                let euler = child.children.first { $0.className == "EulerRotationCurve" }
                let px = channel(pos, "X"), py = channel(pos, "Y"), pz = channel(pos, "Z")
                let rx = channel(euler, "X"), ry = channel(euler, "Y"), rz = channel(euler, "Z")
                let channels = [px, py, pz, rx, ry, rz]
                if channels.contains(where: { !$0.isEmpty }) {
                    let orderIdx = max(0, min(5, Int(euler?.get("RotationOrder")?.asEnum ?? 0)))
                    let ord = orders[orderIdx]
                    var times = Set<Float>()
                    for ch in channels { for k in ch { times.insert(k.t) } }
                    if let tMin = times.min(), let tMax = times.max() {
                        var t = tMin
                        while t < tMax && times.count < 4000 {
                            times.insert(t)
                            t += 1.0 / 30.0
                        }
                        if tMax > length { length = tMax }
                        let sorted = times.sorted()
                        joints[child.name] = sorted.map { ts in
                            let a = [eval(rx, ts), eval(ry, ts), eval(rz, ts)]
                            let r = rot(ord[0], a[ord[0]]) * rot(ord[1], a[ord[1]]) * rot(ord[2], a[ord[2]])
                            let p = Vector3(eval(px, ts), eval(py, ts), eval(pz, ts))
                            return AnimClip.Key(t: ts, cf: r.withPosition(p), style: 0, dir: 0)
                        }
                    }
                }
                walk(child)
            }
        }

        walk(anim)
        guard !joints.isEmpty else { return nil }
        let looped = anim.get("Loop")?.asBool ?? true
        let priority = Int(anim.get("Priority")?.asEnum ?? 0)
        return AnimClip(length: length, looped: looped, priority: priority, joints: joints)
    }
}
