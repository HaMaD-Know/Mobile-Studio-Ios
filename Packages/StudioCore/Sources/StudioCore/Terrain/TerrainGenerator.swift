import Foundation

/// Procedural terrain (port of engine/TerrainGenerator.kt): blended biome heightmaps,
/// optional caves and a sea filled up to y = 0.
public enum TerrainGenerator {
    public enum Biome: String, CaseIterable, Identifiable {
        case water = "Water", marsh = "Marsh", plains = "Plains", hills = "Hills", dunes = "Dunes"
        case canyons = "Canyons", mountains = "Mountains", lavascape = "Lavascape", arctic = "Arctic"
        public var id: String { rawValue }
    }

    public struct Options {
        public var size: Int
        public var seed: Int32
        public var biomes: Set<Biome>
        public var biomeSize: Int
        public var caves: Bool
        public var center: Vector3
        public init(size: Int = 512, seed: Int32 = 618033988, biomes: Set<Biome> = [.water, .plains, .hills, .mountains],
                    biomeSize: Int = 100, caves: Bool = true, center: Vector3 = .zero) {
            self.size = size; self.seed = seed; self.biomes = biomes; self.biomeSize = biomeSize; self.caves = caves; self.center = center
        }
    }

    static let floorY: Float = -32

    static func hash(_ x: Int32, _ y: Int32, _ seed: Int32) -> Float {
        var i = 374761393 &* x &+ 668265263 &* y &+ 144269504 &* seed
        i = (Int32(bitPattern: UInt32(bitPattern: i) >> 13) ^ i) &* 1274126177
        let h = i ^ Int32(bitPattern: UInt32(bitPattern: i) >> 16)
        return Float(h & 16777215) / 16777215
    }
    static func hash3(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: Int32) -> Float { hash(x &* 31 &+ 1000003 &* z, y, seed) }
    static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    static func value(_ x: Float, _ y: Float, _ seed: Int32) -> Float {
        let fx = floor(x), fy = floor(y)
        let ix = Int32(fx), iy = Int32(fy)
        let sx = smooth(x - fx), sy = smooth(y - fy)
        let a = hash(ix, iy, seed), b = hash(ix &+ 1, iy, seed), c = hash(ix, iy &+ 1, seed), d = hash(ix &+ 1, iy &+ 1, seed)
        let top = a + (b - a) * sx
        return top + ((c + (d - c) * sx) - top) * sy
    }

    static func value3(_ x: Float, _ y: Float, _ z: Float, _ seed: Int32) -> Float {
        let ix = Int32(floor(x)), iy = Int32(floor(y)), iz = Int32(floor(z))
        let sx = smooth(x - floor(x)), sy = smooth(y - floor(y)), sz = smooth(z - floor(z))
        func l(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let z0 = l(l(hash3(ix, iy, iz, seed), hash3(ix &+ 1, iy, iz, seed), sx), l(hash3(ix, iy &+ 1, iz, seed), hash3(ix &+ 1, iy &+ 1, iz, seed), sx), sy)
        let z1 = l(l(hash3(ix, iy, iz &+ 1, seed), hash3(ix &+ 1, iy, iz &+ 1, seed), sx), l(hash3(ix, iy &+ 1, iz &+ 1, seed), hash3(ix &+ 1, iy &+ 1, iz &+ 1, seed), sx), sy)
        return l(z0, z1, sz)
    }

    static func fbm(_ x: Float, _ y: Float, _ seed: Int32, _ octaves: Int = 5) -> Float {
        var v: Float = 0, amp: Float = 0.5, freq: Float = 1, total: Float = 0
        for i in 0..<octaves {
            v += value(x * freq, y * freq, Int32(i) &* 1013 &+ seed) * amp
            total += amp; amp *= 0.5; freq *= 2.03
        }
        return v / total
    }

    static func ridged(_ x: Float, _ y: Float, _ seed: Int32) -> Float {
        var v: Float = 0, amp: Float = 0.5, freq: Float = 1, total: Float = 0
        for i in 0..<5 {
            let r = 1 - abs(value(x * freq, y * freq, Int32(i) &* 7919 &+ seed) * 2 - 1)
            v += r * r * amp
            total += amp; amp *= 0.5; freq *= 2.1
        }
        return v / total
    }

    static func height(_ b: Biome, _ x: Float, _ z: Float, _ seed: Int32) -> Float {
        switch b {
        case .water: return fbm(x / 160, z / 160, seed &+ 1) * 16 - 28
        case .marsh: return fbm(x / 60, z / 60, seed &+ 2) * 9 - 6
        case .plains: return fbm(x / 140, z / 140, seed &+ 3) * 10 + 4
        case .hills: return fbm(x / 90, z / 90, seed &+ 4) * 46 + 6
        case .dunes: return fbm(x / 50, z / 50, seed &+ 6) * 6 + 4 + 18 * abs(sin((0.8 * x + 0.6 * z) / 26 + fbm(x / 70, z / 70, seed &+ 5) * 4))
        case .canyons:
            let h = 52 * min(1, max(0, (fbm(x / 120, z / 120, seed &+ 7) - 0.42) / 0.16)) + 6
            return floor(h / 8) * 8 + h.truncatingRemainder(dividingBy: 8) * 0.25
        case .mountains: return ridged(x / 180, z / 180, seed &+ 8) * 150 + 10
        case .lavascape: return ridged(x / 110, z / 110, seed &+ 9) * 50 + 8
        case .arctic: return fbm(x / 110, z / 110, seed &+ 10) * 40 + 6
        }
    }

    static func m(_ n: String) -> Int { TerrainMaterials.fromName(n) }

    static func surfaceMaterial(_ b: Biome, _ y: Float, _ slope: Float) -> Int {
        switch b {
        case .water: return y < -10 ? m("Sand") : m("Mud")
        case .marsh: return slope > 0.6 || y < 1 ? m("Mud") : m("LeafyGrass")
        case .plains: return y < 2 ? m("Sand") : (slope > 0.9 ? m("Ground") : m("Grass"))
        case .hills: return y < 2 ? m("Sand") : (slope > 1.1 ? m("Rock") : (slope > 0.6 ? m("Ground") : m("Grass")))
        case .dunes: return slope > 1.2 ? m("Sandstone") : m("Sand")
        case .canyons: return slope > 0.8 ? m("Sandstone") : (y > 40 ? m("Ground") : m("Sand"))
        case .mountains: return y > 110 ? m("Snow") : (slope > 0.9 ? m("Rock") : (y > 70 ? m("Slate") : m("Grass")))
        case .lavascape: return m(slope > 0.7 ? "Basalt" : "CrackedLava")
        case .arctic: return slope > 1 ? m("Glacier") : (y >= 2 ? m("Snow") : m("Ice"))
        }
    }

    static func under(_ b: Biome, _ depth: Float) -> Int {
        switch b {
        case .dunes, .canyons: return m("Sandstone")
        case .mountains: return m("Rock")
        case .lavascape: return m("Basalt")
        case .arctic: return m(depth < 12 ? "Snow" : "Glacier")
        default: return depth < 10 ? m("Ground") : m("Rock")
        }
    }

    /// Replaces the grid's contents. Returns the number of voxels written.
    @discardableResult
    public static func generate(_ g: TerrainGrid, _ o: Options, progress: (Float) -> Void = { _ in }) -> Int {
        var land = o.biomes.filter { $0 != .water }.sorted { Biome.allCases.firstIndex(of: $0)! < Biome.allCases.firstIndex(of: $1)! }
        if land.isEmpty { land = [.plains] }
        let water = o.biomes.contains(.water)
        let half = Float(o.size) / 2
        let n = o.size / 4
        let ox = Int(floor((o.center.x - half) / 4)), oz = Int(floor((o.center.z - half) / 4))
        let bs = Float(min(max(o.biomeSize, 30), 2000))
        g.clear()
        let w = n + 2
        var heights = [Float](repeating: 0, count: w * w)
        var biomeIdx = [Int](repeating: 0, count: w * w)
        for j in -1...n {
            for i in -1...n {
                let x = Float(ox + i) * 4 + 2, z = Float(oz + j) * 4 + 2
                var hsum: Float = 0, wsum: Float = 0, best: Float = -1, bi = 0
                for (k, b) in land.enumerated() {
                    let v = value(x / bs + Float(k) * 17.3, z / bs - Float(k) * 9.1, o.seed &+ Int32(k) &* 97)
                    let wt = v * v * v * v
                    wsum += wt
                    hsum += height(b, x, z, o.seed) * wt
                    if wt > best { best = wt; bi = k }
                }
                var h = hsum / max(wsum, 1e-6)
                if water {
                    let v2 = value(x / (bs * 1.3) + 51, z / (bs * 1.3) - 33, o.seed &+ 4242)
                    if v2 > 0.62 { h += (height(.water, x, z, o.seed) - h) * min(1, max(0, (v2 - 0.62) / 0.12)) }
                }
                let edge = Float(min(min(i, j), min(n - 1 - i, n - 1 - j)))
                if edge < 6 { h = (h - floorY) * (max(edge, 0) / 6) + floorY }
                heights[i + 1 + (j + 1) * w] = h
                biomeIdx[i + 1 + (j + 1) * w] = bi
            }
        }
        let bottom = Int(floor(floorY / 4))
        let seaTop = -1
        var count = 0
        for j in 0..<n {
            for i in 0..<n {
                let k = i + 1 + (j + 1) * w
                let h = heights[k]
                let biome = land[biomeIdx[k]]
                let sx = (heights[k + 1] - heights[k - 1]) / 8, sz = (heights[k + w] - heights[k - w]) / 8
                let slope = (sx * sx + sz * sz).squareRoot()
                let vx = ox + i, vz = oz + j
                let wx = Float(vx) * 4 + 2, wz = Float(vz) * 4 + 2
                let surf = surfaceMaterial(biome, h, slope)
                let top = Int(floor(h / 4))
                if bottom <= top {
                    for vy in bottom...top {
                        let cy = Float(vy) * 4 + 2
                        let occ = min(1, max(0, (h - Float(vy) * 4) / 4))
                        guard occ > 0.02 else { continue }
                        let depth = h - cy
                        if o.caves && depth > 10 && cy > -24 && value3(wx / 34, cy / 22, wz / 34, o.seed &+ 777) > 0.72 { continue }
                        let mat = vy == bottom ? m("Rock") : (depth < 6 ? surf : under(biome, depth))
                        g.set(vx, vy, vz, mat, occ)
                        count += 1
                    }
                }
                if water && h < 0 {
                    let start = max(top, bottom)
                    if start <= seaTop {
                        for vy in start...seaTop {
                            if g.occupancy(vx, vy, vz) >= 0.99 { continue }
                            if g.material(vx, vy, vz) == 0 { g.set(vx, vy, vz, 1, 1); count += 1 }
                            else { g.setLiquid(vx, vy, vz, true) }
                        }
                    }
                }
            }
            if j % 8 == 0 { progress(Float(j) / Float(n)) }
        }
        g.tidy()
        g.version += 1
        g.modified = true
        progress(1)
        return count
    }
}
