import Foundation

/// Voxel terrain (port of engine/TerrainGrid.kt): 4-stud voxels in 32³ chunks, each voxel a material
/// index (0 air, 1 water, 2+ solids) and an occupancy byte, plus a per-voxel "liquid" flag for
/// water inside partially solid voxels. Encodes to and decodes from Terrain.SmoothGrid.
public final class TerrainGrid {
    public static let CS = 32
    public static let volume = 32 * 32 * 32
    public static let voxel: Float = 4

    public final class Chunk {
        public let cx: Int, cy: Int, cz: Int
        public fileprivate(set) var isUniform = true
        public fileprivate(set) var uMat: UInt8 = 0
        public fileprivate(set) var uOcc: UInt8 = 0
        fileprivate var mat: [UInt8]?
        fileprivate var occ: [UInt8]?
        fileprivate var liquid: Set<Int>?
        /// Encoded bytes as read from the file (re-used when the chunk wasn't edited).
        fileprivate var rle: Data?
        public fileprivate(set) var dirty = false
        public fileprivate(set) var version = 0

        init(_ cx: Int, _ cy: Int, _ cz: Int) { self.cx = cx; self.cy = cy; self.cz = cz }

        public var empty: Bool { isUniform && uMat == 0 }

        private func load() {
            guard !isUniform, mat == nil else { return }
            let (m, o, l) = rle.map(TerrainGrid.expandRle) ?? ([UInt8](repeating: 0, count: TerrainGrid.volume), [UInt8](repeating: 0, count: TerrainGrid.volume), nil)
            mat = m; occ = o; liquid = l
        }

        fileprivate func expand() {
            if isUniform {
                mat = [UInt8](repeating: uMat, count: TerrainGrid.volume)
                occ = [UInt8](repeating: uMat == 0 ? 0 : uOcc, count: TerrainGrid.volume)
                liquid = nil
                isUniform = false
            } else {
                load()
            }
            dirty = true
        }

        public func matAt(_ i: Int) -> Int {
            if isUniform { return Int(uMat) }
            load()
            return Int(mat![i])
        }
        public func occAt(_ i: Int) -> Int {
            if isUniform { return Int(uOcc) }
            load()
            return Int(occ![i])
        }
        public func liquidAt(_ i: Int) -> Bool {
            if isUniform { return false }
            load()
            return liquid?.contains(i) ?? false
        }

        fileprivate func setLiquid(_ i: Int, _ on: Bool) {
            expand()
            if on { if liquid == nil { liquid = [] }; liquid!.insert(i) } else { liquid?.remove(i) }
            version += 1
        }

        /// Collapses a chunk whose voxels are all the same back to the uniform form.
        fileprivate func compact() {
            guard !isUniform, let m = mat, let o = occ, liquid?.isEmpty ?? true else { return }
            let m0 = m[0], o0 = o[0]
            for i in 1..<TerrainGrid.volume where m[i] != m0 || o[i] != o0 { return }
            uMat = m0; uOcc = o0; isUniform = true
            mat = nil; occ = nil; liquid = nil; rle = nil
            dirty = true
        }
    }

    public private(set) var chunks: [Int64: Chunk] = [:]
    public var version = 0
    public var modified = false

    public init() {}

    public static func key(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
        ((Int64(x) & 0x1FFFFF) << 42) | ((Int64(y) & 0x1FFFFF) << 21) | (Int64(z) & 0x1FFFFF)
    }
    @inline(__always) public static func idx(_ x: Int, _ y: Int, _ z: Int) -> Int { z * 32 + x + y * 1024 }

    @inline(__always) static func fdiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    @inline(__always) static func fmod(_ a: Int, _ b: Int) -> Int { let r = a % b; return r < 0 ? r + b : r }

    public func chunk(_ cx: Int, _ cy: Int, _ cz: Int) -> Chunk? { chunks[Self.key(cx, cy, cz)] }

    private func locate(_ vx: Int, _ vy: Int, _ vz: Int) -> (Chunk, Int)? {
        guard let c = chunks[Self.key(Self.fdiv(vx, 32), Self.fdiv(vy, 32), Self.fdiv(vz, 32))] else { return nil }
        return (c, Self.idx(Self.fmod(vx, 32), Self.fmod(vy, 32), Self.fmod(vz, 32)))
    }

    public func material(_ vx: Int, _ vy: Int, _ vz: Int) -> Int {
        guard let (c, i) = locate(vx, vy, vz) else { return 0 }
        return c.matAt(i)
    }

    /// 0...1; zero for air.
    public func occupancy(_ vx: Int, _ vy: Int, _ vz: Int) -> Float {
        guard let (c, i) = locate(vx, vy, vz) else { return 0 }
        return c.matAt(i) != 0 ? Float(c.occAt(i)) / 255 : 0
    }

    public func liquid(_ vx: Int, _ vy: Int, _ vz: Int) -> Bool {
        guard let (c, i) = locate(vx, vy, vz) else { return false }
        return c.liquidAt(i)
    }

    public func set(_ vx: Int, _ vy: Int, _ vz: Int, _ material: Int, _ occupancy: Float) {
        let m = occupancy <= 0.004 ? 0 : material
        let o = m != 0 ? min(255, max(1, Int(min(1, max(0, occupancy)) * 255 + 0.5))) : 0
        let cx = Self.fdiv(vx, 32), cy = Self.fdiv(vy, 32), cz = Self.fdiv(vz, 32)
        let k = Self.key(cx, cy, cz)
        var chunk = chunks[k]
        if chunk == nil {
            if m == 0 { return }
            chunk = Chunk(cx, cy, cz)
            chunks[k] = chunk
        }
        let c = chunk!
        let i = Self.idx(Self.fmod(vx, 32), Self.fmod(vy, 32), Self.fmod(vz, 32))
        if c.matAt(i) == m && c.occAt(i) == o && !c.liquidAt(i) { return }
        c.expand()
        c.mat![i] = UInt8(m)
        c.occ![i] = UInt8(o)
        c.liquid?.remove(i)
        c.version += 1
        version += 1
        modified = true
    }

    /// Marks water inside a partially solid voxel.
    public func setLiquid(_ vx: Int, _ vy: Int, _ vz: Int, _ on: Bool) {
        guard let (c, i) = locate(vx, vy, vz), c.matAt(i) >= 2 else { return }
        c.setLiquid(i, on)
        version += 1
        modified = true
    }

    public func clear() {
        chunks.removeAll()
        version += 1
        modified = true
    }

    /// Drops chunks that ended up empty and collapses uniform ones.
    public func tidy() {
        for (k, c) in chunks {
            c.compact()
            if c.empty { chunks[k] = nil }
        }
    }

    public var isEmpty: Bool { !chunks.values.contains { !$0.empty } }

    public func countCells() -> Int {
        var n = 0
        for c in chunks.values {
            if c.isUniform { if c.uMat != 0 { n += TerrainGrid.volume } }
            else { for i in 0..<TerrainGrid.volume where c.matAt(i) != 0 { n += 1 } }
        }
        return n
    }

    /// Voxel-space bounds (min inclusive, max exclusive) of non-empty chunks.
    public func voxelBounds() -> (lo: (Int, Int, Int), hi: (Int, Int, Int))? {
        var lo = (Int.max, Int.max, Int.max), hi = (Int.min, Int.min, Int.min)
        for c in chunks.values where !c.empty {
            lo = (min(lo.0, c.cx * 32), min(lo.1, c.cy * 32), min(lo.2, c.cz * 32))
            hi = (max(hi.0, c.cx * 32 + 32), max(hi.1, c.cy * 32 + 32), max(hi.2, c.cz * 32 + 32))
        }
        return lo.0 == Int.max ? nil : (lo, hi)
    }

    // MARK: SmoothGrid encoding

    static func expandRle(_ rle: Data) -> ([UInt8], [UInt8], Set<Int>?) {
        var mat = [UInt8](repeating: 0, count: volume), occ = [UInt8](repeating: 0, count: volume)
        var liquid: Set<Int>?
        let b = [UInt8](rle)
        var i = 0, n = 0, last = -1
        while i < b.count {
            let h = Int(b[i]); i += 1
            if h == 255 {
                if last >= 0 { if liquid == nil { liquid = [] }; liquid!.insert(last) }
                continue
            }
            if n >= volume { break }
            let m = h & 63
            var o = m == 0 ? 0 : 255
            if h & 64 != 0, i < b.count { o = Int(b[i]); i += 1 }
            var count = 1
            if h & 128 != 0, i < b.count { count = Int(b[i]) + 1; i += 1 }
            let end = min(volume, n + count)
            for j in n..<end { mat[j] = UInt8(m); occ[j] = UInt8(o) }
            last = end - 1
            n = end
        }
        return (mat, occ, liquid)
    }

    public static func decode(_ data: Data) -> TerrainGrid {
        let g = TerrainGrid()
        let b = [UInt8](data)
        guard b.count >= 2 else { return g }
        var i = 2
        var cx = 0, cy = 0, cz = 0
        while i + 12 <= b.count {
            var d = [0, 0, 0]
            for axis in 0..<3 {
                var v: UInt32 = 0
                for k in 0..<4 { v = (v << 8) | UInt32(b[i + k * 3 + axis]) }
                d[axis] = Int(Int32(bitPattern: v))
            }
            i += 12
            cx += d[0]; cy += d[1]; cz += d[2]
            let start = i
            var n = 0
            var uniform = true
            var firstMat = -1, firstOcc = -1
            while n < volume && i < b.count {
                let h = Int(b[i]); i += 1
                if h == 255 { uniform = false; continue }
                let m = h & 63
                var o = m == 0 ? 0 : 255
                if h & 64 != 0, i < b.count { o = Int(b[i]); i += 1 }
                var count = 1
                if h & 128 != 0, i < b.count { count = Int(b[i]) + 1; i += 1 }
                if firstMat < 0 { firstMat = m; firstOcc = o } else if m != firstMat || o != firstOcc { uniform = false }
                n += count
            }
            while i < b.count && b[i] == 255 { uniform = false; i += 1 }
            let c = Chunk(cx, cy, cz)
            c.rle = Data(b[start..<i])
            if uniform {
                c.isUniform = true
                c.uMat = UInt8(max(firstMat, 0)); c.uOcc = UInt8(max(firstOcc, 0))
            } else {
                c.isUniform = false
            }
            g.chunks[key(cx, cy, cz)] = c
        }
        return g
    }

    public func encode() -> Data {
        var out: [UInt8] = [1, 5]
        var px = 0, py = 0, pz = 0
        let sorted = chunks.values.sorted { ($0.cx, $0.cy, $0.cz) < ($1.cx, $1.cy, $1.cz) }
        for c in sorted {
            let d = [c.cx - px, c.cy - py, c.cz - pz]
            px = c.cx; py = c.cy; pz = c.cz
            var hdr = [UInt8](repeating: 0, count: 12)
            for axis in 0..<3 {
                let v = UInt32(bitPattern: Int32(truncatingIfNeeded: d[axis]))
                for k in 0..<4 { hdr[k * 3 + axis] = UInt8((v >> (24 - UInt32(k) * 8)) & 255) }
            }
            out += hdr
            if !c.dirty, let rle = c.rle {
                out += [UInt8](rle)
                continue
            }
            var i = 0
            while i < TerrainGrid.volume {
                let m = c.matAt(i), o = c.occAt(i)
                if c.liquidAt(i) {
                    out += [UInt8(m | 192), UInt8(o), 0, 255]
                    i += 1
                    continue
                }
                var run = 1
                while run < 256 && i + run < TerrainGrid.volume && c.matAt(i + run) == m && c.occAt(i + run) == o && !c.liquidAt(i + run) { run += 1 }
                let partial = m != 0 && o != 255
                var h = m
                if partial { h |= 64 }
                if run > 1 { h |= 128 }
                out.append(UInt8(h))
                if partial { out.append(UInt8(o)) }
                if run > 1 { out.append(UInt8(run - 1)) }
                i += run
            }
        }
        return Data(out)
    }
}

/// Terrain material table (port of engine/TerrainMaterials.kt). Index = SmoothGrid material id.
public enum TerrainMaterials {
    public static let names = ["Air", "Water", "Grass", "Slate", "Concrete", "Brick", "Sand", "WoodPlanks", "Rock", "Glacier",
                               "Snow", "Sandstone", "Mud", "Basalt", "Ground", "CrackedLava", "Asphalt", "Cobblestone", "Ice",
                               "LeafyGrass", "Salt", "Limestone", "Pavement"]
    /// Enum.Material values for each index.
    public static let enumValues = [1792, 2048, 1280, 800, 816, 848, 1296, 528, 896, 1552, 1328, 912, 1344, 788, 1360, 804, 1376,
                                    880, 1536, 1284, 1392, 820, 836]
    public static let defaultColors: [Color3] = [
        Color3(0, 0, 0), .fromRGB(12, 84, 92), .fromRGB(106, 127, 63), .fromRGB(63, 127, 107), .fromRGB(127, 102, 63),
        .fromRGB(138, 86, 62), .fromRGB(143, 126, 95), .fromRGB(139, 109, 79), .fromRGB(102, 108, 111), .fromRGB(101, 176, 234),
        .fromRGB(195, 199, 218), .fromRGB(137, 90, 71), .fromRGB(58, 46, 36), .fromRGB(30, 30, 37), .fromRGB(102, 92, 59),
        .fromRGB(232, 156, 74), .fromRGB(115, 123, 107), .fromRGB(132, 123, 90), .fromRGB(129, 194, 224), .fromRGB(115, 132, 74),
        .fromRGB(198, 189, 181), .fromRGB(206, 173, 148), .fromRGB(148, 148, 140),
    ]
    public static let solid = Array(2..<names.count)

    public static func fromName(_ n: String) -> Int {
        names.firstIndex { $0.caseInsensitiveCompare(n) == .orderedSame } ?? -1
    }
    public static func fromEnum(_ v: Int) -> Int { enumValues.firstIndex(of: v) ?? -1 }

    /// Terrain.MaterialColors (3 bytes per material) over the defaults.
    public static func colors(_ terrain: Instance?) -> [Color3] {
        var out = defaultColors
        var bytes: [UInt8]?
        switch terrain?.get("MaterialColors") {
        case .binaryString(let b)?: bytes = [UInt8](b.bytes)
        case .string(let s)?: bytes = [UInt8](s.utf8)
        default: break
        }
        if let b = bytes, b.count >= names.count * 3 {
            for i in 2..<names.count { out[i] = .fromRGB(Int(b[i * 3]), Int(b[i * 3 + 1]), Int(b[i * 3 + 2])) }
        }
        return out
    }

    public static func encodeColors(_ c: [Color3]) -> Data {
        var b = [UInt8](repeating: 0, count: names.count * 3)
        for i in 2..<names.count {
            b[i * 3] = UInt8(Color3.c8(c[i].r)); b[i * 3 + 1] = UInt8(Color3.c8(c[i].g)); b[i * 3 + 2] = UInt8(Color3.c8(c[i].b))
        }
        return Data(b)
    }
}

/// Keeps the decoded grid for each Terrain instance and writes it back to SmoothGrid
/// (port of engine/TerrainStore.kt).
public enum TerrainStore {
    private final class Entry {
        weak var terrain: Instance?
        let grid: TerrainGrid
        var source: Data?
        init(_ t: Instance, _ g: TerrainGrid, _ s: Data?) { terrain = t; grid = g; source = s }
    }
    private static var map: [ObjectIdentifier: Entry] = [:]

    private static func smoothGrid(_ t: Instance) -> Data? {
        switch t.props["SmoothGrid"] {
        case .binaryString(let b)?: return b.bytes
        case .string(let s)?: return Data(s.utf8)
        default: return nil
        }
    }

    private static func same(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a.count != b.count { return false }
        if a.count <= 64 { return a == b }
        let pa = a.withUnsafeBytes { $0.baseAddress }, pb = b.withUnsafeBytes { $0.baseAddress }
        return pa == pb || a == b
    }

    /// The grid for a Terrain instance, decoded again whenever SmoothGrid was replaced (load, undo).
    public static func of(_ t: Instance) -> TerrainGrid {
        let id = ObjectIdentifier(t)
        let src = smoothGrid(t)
        if let e = map[id], e.terrain === t, same(e.source, src) { return e.grid }
        let g = src.map(TerrainGrid.decode) ?? TerrainGrid()
        if let old = map[id] { g.version = old.grid.version + 1 }
        map[id] = Entry(t, g, src)
        if map.count > 64 { map = map.filter { $0.value.terrain != nil } }
        return g
    }

    /// Writes the grid into SmoothGrid when it changed; returns (old, new) for undo.
    @discardableResult
    public static func flush(_ t: Instance) -> (old: PropValue?, new: PropValue)? {
        let g = of(t)
        guard g.modified else { return nil }
        g.tidy()
        let data = g.encode()
        let old = t.props["SmoothGrid"]
        let new = PropValue.binaryString(BinaryString(data))
        t.set("SmoothGrid", new, notify: false)
        map[ObjectIdentifier(t)]?.source = smoothGrid(t)
        g.modified = false
        return (old, new)
    }

    public static func terrainOf(_ root: Instance?) -> Instance? {
        guard let root else { return nil }
        let ws = root.className == "Workspace" ? root : (root as? DataModel)?.findService("Workspace") ?? root.children.first { $0.className == "Workspace" }
        return ws?.findFirstChildOfClass("Terrain")
    }

    public static func hasVoxels(_ t: Instance) -> Bool { !of(t).isEmpty }
}
