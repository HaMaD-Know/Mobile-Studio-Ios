import Foundation

/// Terrain editing (port of engine/TerrainOps.kt): shape fills used by scripts and templates,
/// and the Terrain Editor brushes. Occupancy follows Roblox: a voxel whose centre is `d` studs
/// outside a shape gets clamp(0.5 - d / 4, 0, 1).
public enum TerrainOps {
    public enum Brush: String, CaseIterable, Identifiable {
        case add = "Add", subtract = "Subtract", grow = "Grow", erode = "Erode", smooth = "Smooth"
        case flatten = "Flatten", paint = "Paint", seaLevel = "Sea Level"
        public var id: String { rawValue }
    }

    static let V: Float = 4
    static let NB = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]

    @inline(__always) static func center(_ x: Int, _ y: Int, _ z: Int) -> Vector3 {
        Vector3(Float(x) * V + 2, Float(y) * V + 2, Float(z) * V + 2)
    }

    /// Calls `f` for every voxel whose cell touches [lo, hi].
    static func forVoxels(_ lo: Vector3, _ hi: Vector3, _ f: (Int, Int, Int, Vector3) -> Void) {
        let x0 = Int(floor(lo.x / V)), x1 = Int(floor(hi.x / V))
        let y0 = Int(floor(lo.y / V)), y1 = Int(floor(hi.y / V))
        let z0 = Int(floor(lo.z / V)), z1 = Int(floor(hi.z / V))
        guard x1 >= x0, y1 >= y0, z1 >= z0, Int64(x1 - x0) * Int64(y1 - y0) * Int64(z1 - z0) <= 60_000_000 else { return }
        for y in y0...y1 { for z in z0...z1 { for x in x0...x1 { f(x, y, z, center(x, y, z)) } } }
    }

    /// Merge `amount` of `material` into a voxel (TerrainOps.add).
    static func add(_ g: TerrainGrid, _ x: Int, _ y: Int, _ z: Int, _ material: Int, _ amount: Float) {
        guard amount > 0 else { return }
        if material == 0 {
            if amount >= 0.5 { g.set(x, y, z, 0, 0) }
            return
        }
        let occ = g.occupancy(x, y, z), cur = g.material(x, y, z)
        if cur == material {
            if amount > occ { g.set(x, y, z, material, amount) }
        } else if amount >= occ || cur == 0 {
            g.set(x, y, z, material, max(amount, occ))
        }
    }

    static func amount(_ sd: Float) -> Float { min(1, max(0, 0.5 - sd / V)) }

    public static func fillBall(_ g: TerrainGrid, center c: Vector3, radius r: Float, material m: Int) {
        let e = Vector3(r + V, r + V, r + V)
        forVoxels(c - e, c + e) { x, y, z, p in add(g, x, y, z, m, amount((p - c).magnitude - r)) }
    }

    static func boxSD(_ q: Vector3, _ half: Vector3) -> Float {
        let d = q.abs - half
        let outside = Vector3(max(d.x, 0), max(d.y, 0), max(d.z, 0)).magnitude
        return outside + min(max(d.x, max(d.y, d.z)), 0)
    }

    static func bounds(_ cf: CFrame, _ half: Vector3) -> (Vector3, Vector3) {
        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = lo * -1
        for sx: Float in [-1, 1] { for sy: Float in [-1, 1] { for sz: Float in [-1, 1] {
            let p = cf * Vector3(half.x * sx, half.y * sy, half.z * sz)
            lo = lo.min(p); hi = hi.max(p)
        } } }
        return (lo - Vector3(V, V, V), hi + Vector3(V, V, V))
    }

    public static func fillBlock(_ g: TerrainGrid, cframe cf: CFrame, size: Vector3, material m: Int) {
        let half = size / 2
        let (lo, hi) = bounds(cf, half)
        let inv = cf.inverse
        forVoxels(lo, hi) { x, y, z, p in add(g, x, y, z, m, amount(boxSD(inv * p, half))) }
    }

    public static func fillCylinder(_ g: TerrainGrid, cframe cf: CFrame, height: Float, radius: Float, material m: Int) {
        let half = Vector3(radius, height / 2, radius)
        let (lo, hi) = bounds(cf, half)
        let inv = cf.inverse
        forVoxels(lo, hi) { x, y, z, p in
            let q = inv * p
            let dr = (q.x * q.x + q.z * q.z).squareRoot() - radius, dy = abs(q.y) - height / 2
            let sd = min(max(dr, dy), 0) + Vector2(max(dr, 0), max(dy, 0)).magnitude
            add(g, x, y, z, m, amount(sd))
        }
    }

    /// Wedge: the box cut by the plane from the bottom-front edge to the top-back edge.
    public static func fillWedge(_ g: TerrainGrid, cframe cf: CFrame, size: Vector3, material m: Int) {
        let half = size / 2
        let (lo, hi) = bounds(cf, half)
        let inv = cf.inverse
        let n = Vector3(0, size.z, -size.y).unit
        forVoxels(lo, hi) { x, y, z, p in
            let q = inv * p
            add(g, x, y, z, m, amount(max(boxSD(q, half), q.dot(n))))
        }
    }

    /// Fills whole voxels in an axis-aligned region (FillRegion).
    public static func fillRegion(_ g: TerrainGrid, lo: Vector3, hi: Vector3, material m: Int) {
        forVoxels(lo, hi - Vector3(0.01, 0.01, 0.01)) { x, y, z, _ in g.set(x, y, z, m, m == 0 ? 0 : 1) }
    }

    public static func replaceMaterial(_ g: TerrainGrid, lo: Vector3, hi: Vector3, from: Int, to: Int) {
        forVoxels(lo, hi - Vector3(0.01, 0.01, 0.01)) { x, y, z, _ in
            guard g.material(x, y, z) == from else { return }
            g.set(x, y, z, to, to == 0 ? 0 : max(g.occupancy(x, y, z), from == 0 ? 1 : 0))
        }
    }

    static func dominantNeighbor(_ g: TerrainGrid, _ x: Int, _ y: Int, _ z: Int, fallback: Int) -> Int {
        var counts = [Int](repeating: 0, count: TerrainMaterials.names.count)
        for (dx, dy, dz) in NB {
            let m = g.material(x + dx, y + dy, z + dz)
            if m >= 2 && m < counts.count { counts[m] += 1 }
        }
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 else { return fallback }
        return best
    }

    static func neighborAverage(_ g: TerrainGrid, _ x: Int, _ y: Int, _ z: Int) -> Float {
        var s: Float = 0
        for (dx, dy, dz) in NB where g.material(x + dx, y + dy, z + dz) != 1 { s += g.occupancy(x + dx, y + dy, z + dz) }
        return s / Float(NB.count)
    }

    /// One brush dab. `strength` is 0...1; `material` is a TerrainMaterials index.
    public static func brush(_ g: TerrainGrid, _ tool: Brush, center c: Vector3, radius r: Float, strength: Float,
                             material: Int, cube: Bool = false, planeY: Float? = nil) {
        let e = Vector3(r + V, r + V, r + V)
        let s = 0.25 + 0.75 * min(1, max(0, strength))
        func falloff(_ p: Vector3) -> Float {
            let d = p - c
            let dist = cube ? max(abs(d.x), max(abs(d.y), abs(d.z))) : d.magnitude
            return amount(dist - r)
        }
        // Read-before-write so smoothing doesn't feed on its own output.
        var writes: [(Int, Int, Int, Int, Float)] = []
        var liquids: [(Int, Int, Int)] = []
        forVoxels(c - e, c + e) { x, y, z, p in
            let f = falloff(p)
            guard f > 0 else { return }
            let occ = g.occupancy(x, y, z), cur = g.material(x, y, z)
            let solidOcc = cur == 1 ? 0 : occ
            switch tool {
            case .add:
                let target = solidOcc + (f - solidOcc) * s
                if target > solidOcc { writes.append((x, y, z, material, target)) }
            case .subtract:
                guard cur >= 2 else { return }
                let target = solidOcc + ((1 - f) - solidOcc) * s
                if target < solidOcc { writes.append((x, y, z, cur, target)) }
            case .grow:
                let near = solidOcc > 0 || neighborAverage(g, x, y, z) > 0.05
                guard near else { return }
                let target = min(1, solidOcc + f * s * 0.3)
                let m = cur >= 2 ? cur : dominantNeighbor(g, x, y, z, fallback: material)
                if target > solidOcc { writes.append((x, y, z, m, target)) }
            case .erode:
                guard cur >= 2 else { return }
                writes.append((x, y, z, cur, max(0, solidOcc - f * s * 0.3)))
            case .smooth:
                let avg = neighborAverage(g, x, y, z)
                let target = solidOcc + (avg - solidOcc) * f * s
                guard abs(target - solidOcc) > 0.004 else { return }
                let m = cur >= 2 ? cur : dominantNeighbor(g, x, y, z, fallback: material)
                writes.append((x, y, z, m, target))
            case .flatten:
                let plane = planeY ?? c.y
                // Signed distance below the plane: positive = should be solid.
                let want = min(1, max(0, 0.5 + (plane - p.y) / V))
                let target = solidOcc + (want - solidOcc) * f * s
                guard abs(target - solidOcc) > 0.004 else { return }
                let m = cur >= 2 ? cur : dominantNeighbor(g, x, y, z, fallback: material)
                writes.append((x, y, z, m, target))
            case .paint:
                if cur >= 2 && f >= 0.5 && cur != material { writes.append((x, y, z, material, occ)) }
            case .seaLevel:
                guard p.y <= (planeY ?? c.y) else { return }
                if cur == 0 { writes.append((x, y, z, 1, 1)) }
                else if cur >= 2 && occ < 0.99 { liquids.append((x, y, z)) }
            }
        }
        for (x, y, z, m, o) in writes { g.set(x, y, z, o <= 0.004 ? 0 : m, o) }
        for (x, y, z) in liquids { g.setLiquid(x, y, z, true) }
    }
}
