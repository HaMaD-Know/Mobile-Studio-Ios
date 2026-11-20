import Foundation

/// Triangle soup ready for the GPU: 8 floats per vertex (position, normal, uv), plus bounds.
public struct MeshData {
    public var vertices: [Float]
    public var min: [Float]
    public var max: [Float]
    public var vertexCount: Int { vertices.count / 8 }
}

public struct MeshError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Roblox `.mesh` files, versions 1 to 7 (port of render/RbxMesh.kt).
public enum MeshFile {
    public static func parse(_ bytes: Data) throws -> MeshData {
        let b = [UInt8](bytes)
        let head = String(decoding: b.prefix(13), as: UTF8.self)
        guard head.hasPrefix("version ") else { throw MeshError("not a mesh file") }
        let ver = String(head.dropFirst(8).prefix(4))
        guard let nlIdx = b.firstIndex(of: 10) else { throw MeshError("bad header") }
        let nl = nlIdx + 1
        if ver.hasPrefix("1.") { return try parseV1(String(decoding: b, as: UTF8.self), scaleHalf: ver == "1.00") }
        if ver == "2.00" { return try parseV2(b, nl) }
        if ver.hasPrefix("3.") { return try parseV3(b, nl) }
        if ver.hasPrefix("4.") || ver.hasPrefix("5.") { return try parseV4(b, nl) }
        if ver.hasPrefix("6.") || ver.hasPrefix("7.") { return try parseChunked(b, nl) }
        throw MeshError("mesh version \(ver)")
    }

    struct Reader {
        let b: [UInt8]
        var pos: Int
        mutating func need(_ n: Int) throws { if pos + n > b.count || n < 0 { throw MeshError("truncated mesh") } }
        mutating func u8() throws -> Int { try need(1); defer { pos += 1 }; return Int(b[pos]) }
        mutating func u16() throws -> Int { try need(2); defer { pos += 2 }; return Int(b[pos]) | Int(b[pos + 1]) << 8 }
        mutating func i32() throws -> Int {
            try need(4); defer { pos += 4 }
            return Int(Int32(bitPattern: UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24))
        }
        mutating func f32() throws -> Float {
            try need(4); defer { pos += 4 }
            return Float(bitPattern: UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24)
        }
    }

    struct Verts { var pos: [Float]; var nrm: [Float]; var uv: [Float] }

    static func readVerts(_ r: inout Reader, _ n: Int, _ stride: Int) throws -> Verts {
        guard n >= 0, n < 10_000_000 else { throw MeshError("bad vertex count") }
        var v = Verts(pos: .init(repeating: 0, count: n * 3), nrm: .init(repeating: 0, count: n * 3), uv: .init(repeating: 0, count: n * 2))
        for i in 0..<n {
            let start = r.pos
            for c in 0..<3 { v.pos[i * 3 + c] = try r.f32() }
            for c in 0..<3 { v.nrm[i * 3 + c] = try r.f32() }
            v.uv[i * 2] = try r.f32(); v.uv[i * 2 + 1] = try r.f32()
            r.pos = start + stride
        }
        return v
    }

    static func readFaces(_ r: inout Reader, _ n: Int, _ stride: Int = 12) throws -> [Int] {
        guard n >= 0, n < 20_000_000 else { throw MeshError("bad face count") }
        var f = [Int](repeating: 0, count: n * 3)
        for i in 0..<n {
            let s = r.pos
            f[i * 3] = try r.i32(); f[i * 3 + 1] = try r.i32(); f[i * 3 + 2] = try r.i32()
            r.pos = s + stride
        }
        return f
    }

    static func build(_ pos: [Float], _ nrm: [Float], _ uv: [Float], _ faces: [Int], _ f0: Int, _ f1: Int) -> MeshData {
        let n = pos.count / 3
        var out = [Float](repeating: 0, count: max(0, f1 - f0) * 24)
        var mn: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
        var mx: [Float] = [-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        var o = 0
        if f1 > f0 {
            for f in f0..<f1 {
                for k in 0..<3 {
                    let v = faces[f * 3 + k]
                    if v >= 0 && v < n {
                        for c in 0..<3 {
                            let p = pos[v * 3 + c]
                            out[o + c] = p
                            mn[c] = min(mn[c], p); mx[c] = max(mx[c], p)
                        }
                        out[o + 3] = nrm[v * 3]; out[o + 4] = nrm[v * 3 + 1]; out[o + 5] = nrm[v * 3 + 2]
                        out[o + 6] = uv[v * 2]; out[o + 7] = uv[v * 2 + 1]
                    }
                    o += 8
                }
            }
        }
        if mn[0] > mx[0] { mn = [0, 0, 0]; mx = [0, 0, 0] }
        return MeshData(vertices: out, min: mn, max: mx)
    }

    static func parseV1(_ text: String, scaleHalf: Bool) throws -> MeshData {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1, let faces = Int(lines[1].trimmingCharacters(in: .whitespaces)) else { throw MeshError("bad v1 mesh") }
        let body = lines.dropFirst(2).joined(separator: " ")
        var nums: [[Float]] = []
        var cur = body.startIndex
        while let open = body[cur...].firstIndex(of: "["), let close = body[open...].firstIndex(of: "]") {
            nums.append(body[body.index(after: open)..<close].split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) ?? 0 })
            cur = body.index(after: close)
        }
        let count = min(faces * 3, nums.count / 3)
        var pos = [Float](repeating: 0, count: count * 3), nrm = pos, uv = [Float](repeating: 0, count: count * 2)
        let s: Float = scaleHalf ? 0.5 : 1
        for i in 0..<count {
            let p = nums[i * 3], nn = nums[i * 3 + 1], t = nums[i * 3 + 2]
            for c in 0..<3 {
                pos[i * 3 + c] = (c < p.count ? p[c] : 0) * s
                nrm[i * 3 + c] = c < nn.count ? nn[c] : 0
            }
            uv[i * 2] = t.count > 0 ? t[0] : 0
            uv[i * 2 + 1] = 1 - (t.count > 1 ? t[1] : 0)
        }
        return build(pos, nrm, uv, Array(0..<count), 0, count / 3)
    }

    static func parseV2(_ b: [UInt8], _ at: Int) throws -> MeshData {
        var r = Reader(b: b, pos: at)
        let hs = try r.u16(), vs = try r.u8(), fs = try r.u8()
        let nv = try r.i32(), nf = try r.i32()
        r.pos = at + hs
        let v = try readVerts(&r, nv, vs)
        let f = try readFaces(&r, nf, fs)
        return build(v.pos, v.nrm, v.uv, f, 0, nf)
    }

    static func parseV3(_ b: [UInt8], _ at: Int) throws -> MeshData {
        var r = Reader(b: b, pos: at)
        let hs = try r.u16(), vs = try r.u8(), fs = try r.u8()
        _ = try r.u16()
        let nl = try r.u16()
        let nv = try r.i32(), nf = try r.i32()
        r.pos = at + hs
        let v = try readVerts(&r, nv, vs)
        let f = try readFaces(&r, nf, fs)
        let lods = try (0..<nl).map { _ in try r.i32() }
        let end = nl >= 2 ? max(1, min(nf, lods[1])) : nf
        return build(v.pos, v.nrm, v.uv, f, nl >= 2 ? max(0, min(end, lods[0])) : 0, end)
    }

    static func parseV4(_ b: [UInt8], _ at: Int) throws -> MeshData {
        var r = Reader(b: b, pos: at)
        let hs = try r.u16()
        _ = try r.u16()
        let nv = try r.i32(), nf = try r.i32()
        let nl = try r.u16(), nBones = try r.u16()
        r.pos = at + hs
        let v = try readVerts(&r, nv, 40)
        if nBones > 0 { r.pos += nv * 8 }
        let f = try readFaces(&r, nf)
        let lods = try (0..<nl).map { _ in try r.i32() }
        let end = nl >= 2 ? max(1, min(nf, lods[1])) : nf
        return build(v.pos, v.nrm, v.uv, f, nl >= 2 ? max(0, min(end, lods[0])) : 0, end)
    }

    static func parseChunked(_ b: [UInt8], _ at: Int) throws -> MeshData {
        var r = Reader(b: b, pos: at)
        var core: Verts?
        var faces: [Int]?
        var lods: [Int]?
        while b.count - r.pos >= 16 {
            let name = String(decoding: b[r.pos..<r.pos + 8].prefix { $0 != 0 }, as: UTF8.self)
            r.pos += 8
            let cver = try r.i32(), size = try r.i32()
            let start = r.pos
            guard size >= 0, start + size <= b.count else { break }
            if name == "COREMESH" {
                switch cver {
                case 1:
                    let nv = try r.i32()
                    core = try readVerts(&r, nv, 40)
                    faces = try readFaces(&r, try r.i32())
                case 2:
                    let len = try r.i32()
                    let m = try Draco.decode(b, r.pos, min(len, size - 4))
                    guard let posAtt = m.attribute(0), posAtt.components == 3 else { throw MeshError("Draco mesh without positions") }
                    let n = m.numPoints
                    let nrm = m.attribute(1).flatMap { $0.components == 3 ? $0.values : nil } ?? smoothNormals(posAtt.values, m.faces)
                    var uv = [Float](repeating: 0, count: n * 2)
                    if let u = m.attribute(3), u.components >= 2 {
                        for i in 0..<(n * 2) { uv[i] = u.values[(i / 2) * u.components + (i % 2)] }
                    }
                    core = Verts(pos: posAtt.values, nrm: nrm, uv: uv)
                    faces = m.faces
                default:
                    throw MeshError("mesh chunk version \(cver)")
                }
            } else if name == "LODS" {
                _ = try r.u16(); _ = try r.u8()
                let n = try r.i32()
                lods = try (0..<max(0, n)).map { _ in try r.i32() }
            }
            r.pos = start + size
        }
        guard let v = core else { throw MeshError("mesh without geometry") }
        let f = faces ?? []
        let nf = f.count / 3
        let end = (lods?.count ?? 0) >= 2 ? max(1, min(nf, lods![1])) : nf
        let begin = (lods?.count ?? 0) >= 2 ? max(0, min(end, lods![0])) : 0
        return build(v.pos, v.nrm, v.uv, f, begin, end)
    }

    public static func smoothNormals(_ pos: [Float], _ faces: [Int]) -> [Float] {
        var n = [Float](repeating: 0, count: pos.count)
        let nv = pos.count / 3
        var f = 0
        while f + 2 < faces.count {
            let a = faces[f], b = faces[f + 1], c = faces[f + 2]
            f += 3
            guard a >= 0, a < nv, b >= 0, b < nv, c >= 0, c < nv else { continue }
            let ux = pos[b * 3] - pos[a * 3], uy = pos[b * 3 + 1] - pos[a * 3 + 1], uz = pos[b * 3 + 2] - pos[a * 3 + 2]
            let vx = pos[c * 3] - pos[a * 3], vy = pos[c * 3 + 1] - pos[a * 3 + 1], vz = pos[c * 3 + 2] - pos[a * 3 + 2]
            let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
            for v in [a, b, c] { n[v * 3] += nx; n[v * 3 + 1] += ny; n[v * 3 + 2] += nz }
        }
        for v in 0..<nv {
            let l = (n[v * 3] * n[v * 3] + n[v * 3 + 1] * n[v * 3 + 1] + n[v * 3 + 2] * n[v * 3 + 2]).squareRoot()
            if l > 1e-12 { n[v * 3] /= l; n[v * 3 + 1] /= l; n[v * 3 + 2] /= l } else { n[v * 3 + 1] = 1 }
        }
        return n
    }
}
