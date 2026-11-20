import Foundation
import StudioCore

/// Ray and overlap queries against parts (port of engine/Geometry.kt, used by WorldRoot methods
/// and the Play session).
public enum Geometry {
    public struct Hit {
        public let part: Instance
        public let t: Float
        public let point: Vector3
        public let normal: Vector3
    }

    /// Ray vs box centred at the origin. Returns (t, local normal).
    public static func rayBox(_ o: Vector3, _ d: Vector3, _ h: Vector3) -> (Float, Vector3)? {
        var tMin: Float = -.greatestFiniteMagnitude, tMax: Float = .greatestFiniteMagnitude
        var nMin = Vector3.zero
        for i in 0..<3 {
            if abs(d[i]) < 1e-9 {
                if o[i] < -h[i] || o[i] > h[i] { return nil }
                continue
            }
            var t1 = (-h[i] - o[i]) / d[i], t2 = (h[i] - o[i]) / d[i]
            var n = Vector3.zero; n[i] = -1
            if t1 > t2 { swap(&t1, &t2); n[i] = 1 }
            if t1 > tMin { tMin = t1; nMin = n }
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }
        if tMax < 0 { return nil }
        return tMin >= 0 ? (tMin, nMin) : (0, -nMin)
    }

    static func raySphere(_ o: Vector3, _ d: Vector3, _ r: Float) -> (Float, Vector3)? {
        let a = d.dot(d), b = o.dot(d), c = o.dot(o) - r * r
        let disc = b * b - a * c
        if disc < 0 { return nil }
        var t = (-b - disc.squareRoot()) / a
        if t < 0 { t = (-b + disc.squareRoot()) / a }
        if t < 0 { return nil }
        return (t, (o + d * t).unit)
    }

    /// Ray vs wedge: box test, then reject hits above the slope plane.
    static func rayWedge(_ o: Vector3, _ d: Vector3, _ h: Vector3) -> (Float, Vector3)? {
        // Slope plane passes through (y=-h, z=-h) and (y=+h, z=+h); solid is below/behind it.
        let n = Vector3(0, h.z, -h.y).unit
        guard let (tb, nb) = rayBox(o, d, h) else { return nil }
        let p = o + d * tb
        if n.dot(p) <= 1e-4 { return (tb, nb) }
        let den = n.dot(d)
        guard abs(den) > 1e-9 else { return nil }
        let t = -n.dot(o) / den
        guard t >= 0 else { return nil }
        let q = o + d * t
        if abs(q.x) <= h.x + 1e-4 && abs(q.y) <= h.y + 1e-4 && abs(q.z) <= h.z + 1e-4 { return (t, n) }
        return nil
    }

    /// Ray (direction length = max distance) vs one part.
    public static func rayPart(_ p: Instance, origin: Vector3, direction: Vector3) -> Hit? {
        let cf = PartData.cframe(p), size = PartData.size(p)
        let lo = cf.pointToObject(origin), ld = cf.vectorToObject(direction)
        let r: (Float, Vector3)?
        switch PartData.shape(p) {
        case .ball: r = raySphere(lo, ld, min(size.x, size.y, size.z) / 2)
        case .wedge: r = rayWedge(lo, ld, size * 0.5)
        default: r = rayBox(lo, ld, size * 0.5)
        }
        guard let (t, n) = r, t <= 1 else { return nil }
        return Hit(part: p, t: t, point: origin + direction * t, normal: cf.vectorToWorld(n).unit)
    }

    /// Closest hit among parts. `accept` filters candidates (CanQuery, params...).
    public static func raycast(_ parts: [Instance], origin: Vector3, direction: Vector3, accept: (Instance) -> Bool) -> Hit? {
        var best: Hit?
        for p in parts where accept(p) {
            if let h = rayPart(p, origin: origin, direction: direction), h.t < (best?.t ?? .greatestFiniteMagnitude) { best = h }
        }
        return best
    }

    /// World-space AABB of a part.
    public static func aabb(_ p: Instance) -> (Vector3, Vector3) {
        let cf = PartData.cframe(p), h = PartData.size(p) * 0.5
        let e = Vector3(abs(cf.r00) * h.x + abs(cf.r01) * h.y + abs(cf.r02) * h.z,
                        abs(cf.r10) * h.x + abs(cf.r11) * h.y + abs(cf.r12) * h.z,
                        abs(cf.r20) * h.x + abs(cf.r21) * h.y + abs(cf.r22) * h.z)
        return (cf.position - e, cf.position + e)
    }

    /// Oriented box vs oriented box (separating axis test).
    public static func obbOverlap(_ a: CFrame, _ ha: Vector3, _ b: CFrame, _ hb: Vector3) -> Bool {
        let axesA = [a.rightVector, a.upVector, a.backVector], axesB = [b.rightVector, b.upVector, b.backVector]
        let t = b.position - a.position
        var axes = axesA + axesB
        for x in axesA { for y in axesB { let c = x.cross(y); if c.magnitude > 1e-5 { axes.append(c.unit) } } }
        for ax in axes {
            let ra = abs(axesA[0].dot(ax)) * ha.x + abs(axesA[1].dot(ax)) * ha.y + abs(axesA[2].dot(ax)) * ha.z
            let rb = abs(axesB[0].dot(ax)) * hb.x + abs(axesB[1].dot(ax)) * hb.y + abs(axesB[2].dot(ax)) * hb.z
            if abs(t.dot(ax)) > ra + rb { return false }
        }
        return true
    }

    public static func partsInBox(_ parts: [Instance], _ cf: CFrame, _ size: Vector3, accept: (Instance) -> Bool) -> [Instance] {
        parts.filter { accept($0) && obbOverlap(cf, size * 0.5, PartData.cframe($0), PartData.size($0) * 0.5) }
    }

    public static func partsInRadius(_ parts: [Instance], _ c: Vector3, _ r: Float, accept: (Instance) -> Bool) -> [Instance] {
        parts.filter { p in
            guard accept(p) else { return false }
            let cf = PartData.cframe(p), h = PartData.size(p) * 0.5
            let l = cf.pointToObject(c)
            let q = Vector3(max(-h.x, min(h.x, l.x)), max(-h.y, min(h.y, l.y)), max(-h.z, min(h.z, l.z)))
            return (l - q).magnitude <= r
        }
    }
}
