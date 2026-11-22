import Foundation

/// Triangles for one terrain chunk. `solid` is interleaved pos(3) normal(3) colour(4) floats,
/// `water` is pos(3) normal(3).
public struct TerrainChunkMesh {
    public let key: Int64
    public let stamp: Int
    public let solid: [Float]
    public let water: [Float]
    public let min: Vector3
    public let max: Vector3
    public var solidVertexCount: Int { solid.count / 10 }
    public var waterVertexCount: Int { water.count / 6 }
    public var isEmpty: Bool { solid.isEmpty && water.isEmpty }
}

/// Smooth terrain mesher (port of engine/TerrainMesher.kt): naive surface nets over the voxel
/// occupancies with an iso level of 0.5. One vertex per cell that the surface crosses, quads
/// across every sign-changing edge, per-vertex material colour with a little per-cell variation.
public enum TerrainMesher {
    static let S = 34          // samples per axis (voxels -1 ... 32)
    static let C = 33          // cells per axis
    static let corners = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
    static let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]

    @inline(__always) static func si(_ i: Int, _ j: Int, _ k: Int) -> Int { (j * S + k) * S + i }
    @inline(__always) static func ci(_ i: Int, _ j: Int, _ k: Int) -> Int { (j * C + k) * C + i }

    /// Changes whenever this chunk or a neighbour changes (re-mesh key).
    public static func stamp(_ g: TerrainGrid, _ cx: Int, _ cy: Int, _ cz: Int) -> Int {
        var h = 17
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            let v = g.chunk(cx + dx, cy + dy, cz + dz).map { $0.version + 1 + ($0.isUniform ? Int($0.uMat) * 1000 : 0) } ?? 0
            h = h &* 31 &+ v
        } } }
        return h
    }

    public static func mesh(_ g: TerrainGrid, _ cx: Int, _ cy: Int, _ cz: Int, colors: [Color3]) -> TerrainChunkMesh {
        let key = TerrainGrid.key(cx, cy, cz)
        let st = stamp(g, cx, cy, cz)
        let lo = Vector3(Float(cx * 32) * 4, Float(cy * 32) * 4, Float(cz * 32) * 4)
        let hi = lo + Vector3(128, 128, 128)
        let empty = TerrainChunkMesh(key: key, stamp: st, solid: [], water: [], min: lo, max: hi)

        // Skip chunks whose whole neighbourhood is uniformly empty / solid / water.
        var kinds = Set<Int>()
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            guard let c = g.chunk(cx + dx, cy + dy, cz + dz) else { kinds.insert(0); continue }
            if !c.isUniform { kinds.insert(-1) }
            else if c.uMat == 0 { kinds.insert(0) }
            else if c.uMat == 1 { kinds.insert(c.uOcc >= 128 ? 2 : 0) }
            else { kinds.insert(c.uOcc >= 128 ? 1 : 0) }
        } } }
        if kinds.count == 1 && !kinds.contains(-1) { return empty }

        let ox = cx * 32 - 1, oy = cy * 32 - 1, oz = cz * 32 - 1
        var solidD = [Float](repeating: 0, count: S * S * S)
        var waterD = [Float](repeating: 0, count: S * S * S)
        var mats = [UInt8](repeating: 0, count: S * S * S)
        var anyIn = false, anyOut = false, anyWater = false
        for j in 0..<S {
            for k in 0..<S {
                for i in 0..<S {
                    let vx = ox + i, vy = oy + j, vz = oz + k
                    guard let ch = g.chunk(TerrainGrid.fdiv(vx, 32), TerrainGrid.fdiv(vy, 32), TerrainGrid.fdiv(vz, 32)) else { anyOut = true; continue }
                    let id = TerrainGrid.idx(TerrainGrid.fmod(vx, 32), TerrainGrid.fmod(vy, 32), TerrainGrid.fmod(vz, 32))
                    let m = ch.matAt(id)
                    let s = si(i, j, k)
                    if m == 0 { anyOut = true; continue }
                    let o = Float(ch.occAt(id)) / 255
                    mats[s] = UInt8(m)
                    if m == 1 {
                        waterD[s] = o; anyOut = true
                        if o >= 0.5 { anyWater = true }
                    } else {
                        solidD[s] = o
                        if o >= 0.5 { anyIn = true } else { anyOut = true }
                        if ch.liquidAt(id) { waterD[s] = 1; anyWater = true }
                    }
                }
            }
        }
        let hasSurface = anyIn && anyOut
        if !hasSurface && !anyWater { return empty }

        var solid: [Float] = []
        if hasSurface {
            let (pos, nrm, vid) = vertices(solidD, ox, oy, oz)
            var colors32 = [SIMD4<Float>](repeating: .zero, count: pos.count / 3)
            for j in 0..<C { for k in 0..<C { for i in 0..<C {
                let v = vid[ci(i, j, k)]
                guard v >= 0 else { continue }
                var best: Float = -1, bm = 2
                for (dx, dy, dz) in corners {
                    let s = si(i + dx, j + dy, k + dz)
                    if mats[s] >= 2 && solidD[s] > best { best = solidD[s]; bm = Int(mats[s]) }
                }
                let c = bm < colors.count ? colors[bm] : colors[2]
                let px = Int32(floor(pos[v * 3] * 0.5)), py = Int32(floor(pos[v * 3 + 1] * 0.5)), pz = Int32(floor(pos[v * 3 + 2] * 0.5))
                var hsh = (px &* 73856093) ^ (py &* 19349663) ^ (pz &* 83492791)
                hsh = hsh ^ Int32(bitPattern: UInt32(bitPattern: hsh) >> 13)
                let jitter = Float(hsh & 255) / 255 * 0.12 + 0.93
                colors32[v] = SIMD4(min(1, c.r * jitter), min(1, c.g * jitter), min(1, c.b * jitter), 1)
            } } }
            solid.reserveCapacity(pos.count * 20)
            func push(_ v: Int) {
                solid.append(pos[v * 3]); solid.append(pos[v * 3 + 1]); solid.append(pos[v * 3 + 2])
                solid.append(nrm[v * 3]); solid.append(nrm[v * 3 + 1]); solid.append(nrm[v * 3 + 2])
                let c = colors32[v]
                solid.append(c.x); solid.append(c.y); solid.append(c.z); solid.append(1)
            }
            faces(solidD, vid, pos, filter: nil) { a, b, c in push(a); push(b); push(c) }
        }
        var water: [Float] = []
        if anyWater {
            let (pos, _, vid) = vertices(waterD, ox, oy, oz)
            // Only water/air boundaries: skip faces against solid terrain.
            faces(waterD, vid, pos, filter: solidD) { a, b, c in
                let p0 = Vector3(pos[a * 3], pos[a * 3 + 1], pos[a * 3 + 2])
                let p1 = Vector3(pos[b * 3], pos[b * 3 + 1], pos[b * 3 + 2])
                let p2 = Vector3(pos[c * 3], pos[c * 3 + 1], pos[c * 3 + 2])
                let n = (p1 - p0).cross(p2 - p0).unit
                for p in [p0, p1, p2] {
                    water.append(p.x); water.append(p.y); water.append(p.z)
                    water.append(n.x); water.append(n.y); water.append(n.z)
                }
            }
        }
        return TerrainChunkMesh(key: key, stamp: st, solid: solid, water: water, min: lo, max: hi)
    }

    /// Surface-net vertex per crossing cell: (positions, normals, cell -> vertex index).
    static func vertices(_ f: [Float], _ ox: Int, _ oy: Int, _ oz: Int) -> ([Float], [Float], [Int32]) {
        var vid = [Int32](repeating: -1, count: C * C * C)
        var pos: [Float] = [], nrm: [Float] = []
        var d = [Float](repeating: 0, count: 8)
        for j in 0..<C {
            for k in 0..<C {
                for i in 0..<C {
                    var mask = 0
                    for (n, (dx, dy, dz)) in corners.enumerated() {
                        d[n] = f[si(i + dx, j + dy, k + dz)] - 0.5
                        if d[n] >= 0 { mask |= 1 << n }
                    }
                    if mask == 0 || mask == 255 { continue }
                    var sx: Float = 0, sy: Float = 0, sz: Float = 0, cnt: Float = 0
                    for (a, b) in edges where (d[a] >= 0) != (d[b] >= 0) {
                        let t = d[a] / (d[a] - d[b])
                        let ca = corners[a], cb = corners[b]
                        sx += Float(ca.0) + Float(cb.0 - ca.0) * t
                        sy += Float(ca.1) + Float(cb.1 - ca.1) * t
                        sz += Float(ca.2) + Float(cb.2 - ca.2) * t
                        cnt += 1
                    }
                    pos.append((Float(ox + i) + sx / cnt + 0.5) * 4)
                    pos.append((Float(oy + j) + sy / cnt + 0.5) * 4)
                    pos.append((Float(oz + k) + sz / cnt + 0.5) * 4)
                    let gx = (d[1] + d[3] + d[5] + d[7]) - (d[0] + d[2] + d[4] + d[6])
                    let gy = (d[2] + d[3] + d[6] + d[7]) - (d[0] + d[1] + d[4] + d[5])
                    let gz = (d[4] + d[5] + d[6] + d[7]) - (d[0] + d[1] + d[2] + d[3])
                    let len = (gx * gx + gy * gy + gz * gz).squareRoot()
                    if len > 1e-6 { nrm.append(-gx / len); nrm.append(-gy / len); nrm.append(-gz / len) }
                    else { nrm.append(0); nrm.append(1); nrm.append(0) }
                    vid[ci(i, j, k)] = Int32(pos.count / 3 - 1)
                }
            }
        }
        return (pos, nrm, vid)
    }

    /// Two triangles per sign-changing edge owned by this chunk, wound to face outwards.
    static func faces(_ f: [Float], _ vid: [Int32], _ pos: [Float], filter: [Float]?, _ out: (Int, Int, Int) -> Void) {
        func tri(_ a: Int, _ b: Int, _ c: Int, _ e: (Float, Float, Float)) {
            let ux = pos[b * 3] - pos[a * 3], uy = pos[b * 3 + 1] - pos[a * 3 + 1], uz = pos[b * 3 + 2] - pos[a * 3 + 2]
            let vx = pos[c * 3] - pos[a * 3], vy = pos[c * 3 + 1] - pos[a * 3 + 1], vz = pos[c * 3 + 2] - pos[a * 3 + 2]
            let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            guard len >= 1e-6 else { return }
            if nx * e.0 + ny * e.1 + nz * e.2 >= 0 { out(a, b, c) } else { out(a, c, b) }
        }
        for j in 1..<C {
            for k in 1..<C {
                for i in 1..<C {
                    let s0 = si(i, j, k)
                    let inside = f[s0] >= 0.5
                    for axis in 0..<3 {
                        let s1 = axis == 0 ? si(i + 1, j, k) : (axis == 1 ? si(i, j + 1, k) : si(i, j, k + 1))
                        guard inside != (f[s1] >= 0.5) else { continue }
                        if let filter, filter[inside ? s1 : s0] >= 0.5 { continue }
                        let q: [Int]
                        switch axis {
                        case 0: q = [ci(i, j - 1, k - 1), ci(i, j, k - 1), ci(i, j, k), ci(i, j - 1, k)]
                        case 1: q = [ci(i - 1, j, k - 1), ci(i, j, k - 1), ci(i, j, k), ci(i - 1, j, k)]
                        default: q = [ci(i - 1, j - 1, k), ci(i, j - 1, k), ci(i, j, k), ci(i - 1, j, k)]
                        }
                        let a = Int(vid[q[0]]), b = Int(vid[q[1]]), c = Int(vid[q[2]]), d = Int(vid[q[3]])
                        guard a >= 0, b >= 0, c >= 0, d >= 0 else { continue }
                        let sgn: Float = inside ? 1 : -1
                        let e = (axis == 0 ? sgn : 0, axis == 1 ? sgn : 0, axis == 2 ? sgn : 0)
                        tri(a, b, c, e)
                        tri(a, c, d, e)
                    }
                }
            }
        }
    }

    // MARK: raycast

    /// Trilinear solid occupancy at a world point.
    public static func density(_ g: TerrainGrid, _ p: Vector3) -> Float {
        let ux = p.x / 4 - 0.5, uy = p.y / 4 - 0.5, uz = p.z / 4 - 0.5
        let x0 = Int(floor(ux)), y0 = Int(floor(uy)), z0 = Int(floor(uz))
        let fx = ux - Float(x0), fy = uy - Float(y0), fz = uz - Float(z0)
        func o(_ x: Int, _ y: Int, _ z: Int) -> Float { g.material(x, y, z) == 1 ? 0 : g.occupancy(x, y, z) }
        let c00 = o(x0, y0, z0) * (1 - fx) + o(x0 + 1, y0, z0) * fx
        let c10 = o(x0, y0 + 1, z0) * (1 - fx) + o(x0 + 1, y0 + 1, z0) * fx
        let c01 = o(x0, y0, z0 + 1) * (1 - fx) + o(x0 + 1, y0, z0 + 1) * fx
        let c11 = o(x0, y0 + 1, z0 + 1) * (1 - fx) + o(x0 + 1, y0 + 1, z0 + 1) * fx
        return (c00 * (1 - fy) + c10 * fy) * (1 - fz) + (c01 * (1 - fy) + c11 * fy) * fz
    }

    public struct RayHit {
        public let t: Float
        public let point: Vector3
        public let normal: Vector3
        public let material: Int
    }

    /// First crossing of the 0.5 iso-surface along origin + dir * t, t in [0, maxDist] (dir normalised).
    public static func raycast(_ g: TerrainGrid, origin: Vector3, dir: Vector3, maxDist: Float) -> RayHit? {
        guard !g.chunks.isEmpty, maxDist > 0 else { return nil }
        let d = dir.unit
        var prevT: Float = 0
        var prev = density(g, origin)
        if prev >= 0.5 { return RayHit(t: 0, point: origin, normal: normal(g, origin), material: materialAt(g, origin)) }
        var t: Float = 0
        let step: Float = 1
        while t < maxDist {
            t = min(maxDist, t + step)
            let p = origin + d * t
            let v = density(g, p)
            if v >= 0.5 {
                var a = prevT, b = t
                for _ in 0..<10 {
                    let m = (a + b) / 2
                    if density(g, origin + d * m) >= 0.5 { b = m } else { a = m }
                }
                let hp = origin + d * b
                return RayHit(t: b, point: hp, normal: normal(g, hp), material: materialAt(g, hp - d * 0.5))
            }
            prev = v
            prevT = t
            // Skip quickly through empty chunks.
            if v == 0 && g.chunk(TerrainGrid.fdiv(Int(floor(p.x / 4)), 32), TerrainGrid.fdiv(Int(floor(p.y / 4)), 32), TerrainGrid.fdiv(Int(floor(p.z / 4)), 32)) == nil {
                t += 3
            }
        }
        _ = prev
        return nil
    }

    public static func normal(_ g: TerrainGrid, _ p: Vector3) -> Vector3 {
        let e: Float = 1
        let n = Vector3(density(g, p - Vector3(e, 0, 0)) - density(g, p + Vector3(e, 0, 0)),
                        density(g, p - Vector3(0, e, 0)) - density(g, p + Vector3(0, e, 0)),
                        density(g, p - Vector3(0, 0, e)) - density(g, p + Vector3(0, 0, e)))
        let u = n.unit
        return u == .zero ? .yAxis : u
    }

    static func materialAt(_ g: TerrainGrid, _ p: Vector3) -> Int {
        let x = Int(floor(p.x / 4)), y = Int(floor(p.y / 4)), z = Int(floor(p.z / 4))
        var best: Float = 0, m = g.material(x, y, z)
        for dy in -1...1 { for dz in -1...1 { for dx in -1...1 {
            let mm = g.material(x + dx, y + dy, z + dz)
            let o = g.occupancy(x + dx, y + dy, z + dz)
            if mm >= 2 && o > best { best = o; m = mm }
        } } }
        return m
    }
}
