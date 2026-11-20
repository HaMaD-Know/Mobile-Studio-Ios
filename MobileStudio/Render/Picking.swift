import Foundation
import StudioCore

/// CPU ray casts against parts (stands in for engine/Geometry.kt's raycast for editor picking).
enum Picking {
    struct Hit { let part: Instance; let distance: Float; let point: Vector3; let normal: Vector3 }

    /// Ray vs oriented box in the part's local space. Returns distance and local normal.
    static func rayBox(_ o: Vector3, _ d: Vector3, half: Vector3) -> (Float, Vector3)? {
        var tMin: Float = -.greatestFiniteMagnitude, tMax: Float = .greatestFiniteMagnitude
        var nMin = Vector3.zero
        for i in 0..<3 {
            if abs(d[i]) < 1e-9 {
                if o[i] < -half[i] || o[i] > half[i] { return nil }
                continue
            }
            var t1 = (-half[i] - o[i]) / d[i], t2 = (half[i] - o[i]) / d[i]
            var n = Vector3.zero; n[i] = -1
            if t1 > t2 { swap(&t1, &t2); n[i] = 1 }
            if t1 > tMin { tMin = t1; nMin = n }
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }
        if tMax < 0 { return nil }
        return tMin >= 0 ? (tMin, nMin) : (tMax, -nMin)
    }

    static func raySphere(_ o: Vector3, _ d: Vector3, r: Float) -> (Float, Vector3)? {
        let b = o.dot(d), c = o.dot(o) - r * r
        let disc = b * b - c
        if disc < 0 { return nil }
        var t = -b - disc.squareRoot()
        if t < 0 { t = -b + disc.squareRoot() }
        if t < 0 { return nil }
        return (t, (o + d * t).unit)
    }

    static func hitPart(_ p: Instance, origin: Vector3, dir: Vector3) -> Hit? {
        let cf = PartData.cframe(p), size = PartData.size(p)
        let lo = cf.pointToObject(origin), ld = cf.vectorToObject(dir)
        let r: (Float, Vector3)?
        if PartData.shape(p) == .ball {
            r = raySphere(lo, ld, r: min(size.x, size.y, size.z) / 2)
        } else {
            r = rayBox(lo, ld, half: size * 0.5)
        }
        guard let res = r else { return nil }
        let (t, ln) = res
        return Hit(part: p, distance: t, point: origin + dir * t, normal: cf.vectorToWorld(ln))
    }

    /// Closest part hit along a ray. `skipLocked` mirrors Studio: locked parts can't be clicked.
    static func cast(_ parts: [Instance], origin: Vector3, dir: Vector3, skipLocked: Bool = true,
                     ignore: Set<ObjectIdentifier> = []) -> Hit? {
        var best: Hit?
        for p in parts {
            if ignore.contains(ObjectIdentifier(p)) { continue }
            if skipLocked, p.get("Locked")?.asBool == true { continue }
            if PartData.transparency(p) >= 1 { continue }
            if let h = hitPart(p, origin: origin, dir: dir), h.distance < (best?.distance ?? .greatestFiniteMagnitude) { best = h }
        }
        return best
    }

    /// The thing a tap should select: the part, or its top-level Model under Workspace.
    static func selectable(for part: Instance, workspace: Instance, insideModels: Bool) -> Instance {
        if insideModels { return part }
        var top = part
        var p = part.parent
        while let cur = p, cur !== workspace {
            if cur.isA("Model") { top = cur }
            p = cur.parent
        }
        return top
    }

    /// Axis-aligned bounds of a set of parts.
    static func bounds(_ parts: [Instance]) -> (min: Vector3, max: Vector3)? {
        guard !parts.isEmpty else { return nil }
        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        for p in parts {
            let cf = PartData.cframe(p), h = PartData.size(p) * 0.5
            let ext = Vector3(
                abs(cf.r00) * h.x + abs(cf.r01) * h.y + abs(cf.r02) * h.z,
                abs(cf.r10) * h.x + abs(cf.r11) * h.y + abs(cf.r12) * h.z,
                abs(cf.r20) * h.x + abs(cf.r21) * h.y + abs(cf.r22) * h.z)
            lo = lo.min(cf.position - ext); hi = hi.max(cf.position + ext)
        }
        return (lo, hi)
    }

    /// Closest point parameter on line (p0 + t*axis) to a ray.
    static func closestOnAxis(p0: Vector3, axis: Vector3, rayO: Vector3, rayD: Vector3) -> Float? {
        let w = p0 - rayO
        let a = axis.dot(axis), b = axis.dot(rayD), c = rayD.dot(rayD), d = axis.dot(w), e = rayD.dot(w)
        let den = a * c - b * b
        if abs(den) < 1e-6 { return nil }
        return (b * e - c * d) / den
    }

    /// Ray vs plane, returning the hit point.
    static func rayPlane(origin: Vector3, dir: Vector3, point: Vector3, normal: Vector3) -> Vector3? {
        let den = dir.dot(normal)
        if abs(den) < 1e-6 { return nil }
        let t = (point - origin).dot(normal) / den
        return t < 0 ? nil : origin + dir * t
    }
}
