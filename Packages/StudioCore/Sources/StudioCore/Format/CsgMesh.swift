import Foundation

/// Union (PartOperation) mesh data, "CSGMDL" versions 2-6 (port of format/CsgMesh.kt).
public enum CsgMesh {
    static let magic = Array("CSGMDL".utf8)
    static let key: [UInt8] = [86, 46, 110, 88, 49, 32, 48, 4, 52, 105, 12, 119, 12, 1, 94, 0, 26, 96, 55, 105, 29, 82, 43, 7, 79, 36, 89, 101, 83, 4, 122]

    struct Decoded { var pos: [Float]; var nrm: [Float]; var colors: [UInt32]; var indices: [Int] }

    static func xorByte(_ b: [UInt8], _ i: Int) -> UInt8 { b[i] ^ key[i % key.count] }
    static func startsWithMagic(_ b: [UInt8], scrambled: Bool) -> Bool {
        guard b.count >= 10 else { return false }
        for i in 0..<magic.count where (scrambled ? xorByte(b, i) : b[i]) != magic[i] { return false }
        return true
    }
    public static func isCsgMesh(_ d: Data) -> Bool { let b = [UInt8](d.prefix(16)); return startsWithMagic(b, scrambled: true) || startsWithMagic(b, scrambled: false) }

    /// Decode union mesh bytes into a triangle soup (no UVs).
    public static func decode(_ data: Data) throws -> MeshData {
        let raw = [UInt8](data)
        let scrambled: Bool
        if startsWithMagic(raw, scrambled: false) { scrambled = false }
        else if startsWithMagic(raw, scrambled: true) { scrambled = true }
        else { throw MeshError("not a union mesh") }
        let header = (0..<10).map { scrambled ? xorByte(raw, $0) : raw[$0] }
        let version = Int(UInt32(header[6]) | UInt32(header[7]) << 8 | UInt32(header[8]) << 16 | UInt32(header[9]) << 24)
        let m: Decoded
        switch version {
        case 2, 3, 4: m = try decodeList(scrambled ? (0..<raw.count).map { xorByte(raw, $0) } : raw, version)
        case 5, 6: m = try decodePacked(raw)
        default: throw MeshError("union mesh version \(version) isn't supported")
        }
        let uv = [Float](repeating: 0, count: m.pos.count / 3 * 2)
        return MeshFile.build(m.pos, m.nrm, uv, m.indices, 0, m.indices.count / 3)
    }

    static func firstLod(_ all: [Int], _ lods: [Int]?) -> [Int] {
        guard let lods, lods.count >= 2 else { return all }
        let a = max(0, min(all.count, lods[0])), e = max(a, min(all.count, lods[1]))
        return e - a < 3 ? all : Array(all[a..<(e - (e - a) % 3)])
    }

    static func checkIndices(_ idx: [Int], _ nv: Int) throws {
        if idx.contains(where: { $0 < 0 || $0 >= nv }) { throw MeshError("union index out of range") }
    }

    static func decodeList(_ b: [UInt8], _ version: Int) throws -> Decoded {
        var r = MeshFile.Reader(b: b, pos: 42)
        let nv = try r.i32(), stride = try r.i32()
        guard nv >= 0, stride >= 40, nv * stride + 50 <= b.count else { throw MeshError("bad union vertex data") }
        var pos = [Float](repeating: 0, count: nv * 3), nrm = pos
        var col = [UInt32](repeating: 0, count: nv)
        for i in 0..<nv {
            let s = i * stride + 50
            r.pos = s
            for c in 0..<3 { pos[i * 3 + c] = try r.f32() }
            for c in 0..<3 { nrm[i * 3 + c] = try r.f32() }
            col[i] = UInt32(b[s + 27]) << 24 | UInt32(b[s + 24]) << 16 | UInt32(b[s + 25]) << 8 | UInt32(b[s + 26])
        }
        r.pos = nv * stride + 50
        let ni = try r.i32()
        guard ni >= 0, ni * 4 <= b.count - r.pos else { throw MeshError("bad union index count") }
        let idx = try (0..<ni).map { _ in try r.i32() }
        try checkIndices(idx, nv)
        var lods: [Int]?
        if version >= 4, b.count - r.pos >= 4 {
            let n = try r.i32()
            if (1..<65).contains(n), b.count - r.pos >= n * 4 { lods = try (0..<n).map { _ in try r.i32() } }
        }
        return Decoded(pos: pos, nrm: nrm, colors: col, indices: firstLod(idx, lods))
    }

    static func decodePacked(_ b: [UInt8]) throws -> Decoded {
        var r = MeshFile.Reader(b: b, pos: 10)
        func count(_ expect: Int) throws -> Int {
            let n = try r.u16()
            guard expect < 0 || n == expect else { throw MeshError("inconsistent union vertex count") }
            return n
        }
        let nv = try count(-1)
        let pos = try (0..<(nv * 3)).map { _ in try r.f32() }
        _ = try count(nv)
        let nSize = try r.i32()
        guard nSize == nv * 6 else { throw MeshError("bad union normals") }
        let nrm = try (0..<(nv * 3)).map { _ in Float(try r.u16()) / 32767 - 1 }
        _ = try count(nv)
        var col = [UInt32](repeating: 0, count: nv)
        for i in 0..<nv {
            let rr = try r.u8(), g = try r.u8(), bl = try r.u8(), a = try r.u8()
            col[i] = UInt32(a) << 24 | UInt32(rr) << 16 | UInt32(g) << 8 | UInt32(bl)
        }
        _ = try count(nv); r.pos += nv
        _ = try count(nv); r.pos += nv * 8
        _ = try count(nv)
        let tSize = try r.i32(); r.pos += tSize
        let ni = try r.i32(), iSize = try r.i32()
        guard ni >= 0, iSize >= 0, iSize <= b.count - r.pos else { throw MeshError("bad union index data") }
        let idx = try decodeDeltaIndices(b, r.pos, iSize, ni)
        try checkIndices(idx, nv)
        r.pos += iSize
        var lods: [Int]?
        if b.count - r.pos >= 4 {
            let n = try r.i32()
            if (1..<65).contains(n), b.count - r.pos >= n * 4 { lods = try (0..<n).map { _ in try r.i32() } }
        }
        return Decoded(pos: pos, nrm: nrm, colors: col, indices: firstLod(idx, lods))
    }

    static func decodeDeltaIndices(_ b: [UInt8], _ start: Int, _ size: Int, _ count: Int) throws -> [Int] {
        var out = [Int](repeating: 0, count: count)
        var p = start
        let end = start + size
        var cur = 0
        for i in 0..<count {
            guard p < end else { throw MeshError("union index data too short") }
            let x = Int(b[p]); p += 1
            var v: Int
            if x < 128 {
                v = x >= 64 ? x - 128 : x
            } else {
                guard p + 2 <= end else { throw MeshError("union index data too short") }
                v = ((x & 127) << 16) | (Int(b[p]) << 8) | Int(b[p + 1])
                p += 2
                if v >= 4_194_304 { v -= 8_388_608 }
            }
            cur += v
            out[i] = cur
        }
        guard p == end else { throw MeshError("union index data has \(end - p) extra bytes") }
        return out
    }

    /// The union mesh bytes stored on a PartOperation (inline MeshData / MeshData2).
    public static func inlineData(_ p: Instance) -> Data? {
        for k in ["MeshData2", "MeshData"] {
            switch p.get(k) {
            case .binaryString(let b)? where b.bytes.count > 16: return b.bytes
            case .sharedString(let s)? where s.bytes.count > 16: return s.bytes
            case .string(let s)? where s.utf8.count > 16: return Data(s.utf8)
            default: continue
            }
        }
        return nil
    }

    /// Mesh bytes out of a downloaded union asset (a model file holding the PartOperation).
    public static func fromAsset(_ d: Data) throws -> Data {
        if isCsgMesh(d) { return d }
        let doc = try RbxFile.read(d)
        for r in doc.roots {
            for i in [r] + r.descendants() { if let m = inlineData(i) { return m } }
        }
        throw MeshError("the union asset has no mesh")
    }
}
