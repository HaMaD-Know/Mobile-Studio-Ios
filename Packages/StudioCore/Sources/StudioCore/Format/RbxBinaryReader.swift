import Foundation

public struct RbxDocument {
    public var roots: [Instance]
    public var meta: OrderedDict<String>
    public var warnings: [String]
}

/// Reader for the `<roblox!` binary place/model format (port of format/RbxBinaryReader.kt).
final class RbxBinaryReader {
    private struct Chunk { let name: String; let data: [UInt8] }
    private struct ClassInfo { let name: String; let refs: [Int32] }

    private let data: [UInt8]
    private var warnings: [String] = []
    private var instances: [Int32: Instance] = [:]
    private var classes: [Int32: ClassInfo] = [:]
    private var sharedStrings: [Data] = []
    private var pendingRefs: [(Instance, String, Int32)] = []
    private var meta = OrderedDict<String>()

    init(_ data: [UInt8]) { self.data = data }

    func read() throws -> RbxDocument {
        var r = ByteReader(data)
        r.pos = 14
        let version = try r.u16()
        if version != 0 { warnings.append("Unknown file version \(version)") }
        _ = try r.i32(); _ = try r.i32(); try r.skip(8)

        var chunks: [Chunk] = []
        while r.remaining >= 16 {
            let rawName = try r.bytes(4)
            let name = String(decoding: rawName.prefix { $0 != 0 }, as: UTF8.self)
            let compressed = Int(try r.i32()), size = Int(try r.i32())
            _ = try r.i32()
            let body: [UInt8]
            if compressed == 0 {
                body = try r.bytes(size)
            } else {
                let start = r.pos
                try r.skip(compressed)
                body = try decompress(start, compressed, size)
            }
            chunks.append(Chunk(name: name, data: body))
            if name == "END" { break }
        }

        for c in chunks where c.name == "META" { try readMeta(c.data) }
        for c in chunks where c.name == "SSTR" { try readSstr(c.data) }
        for c in chunks where c.name == "INST" { try readInst(c.data) }
        for c in chunks where c.name == "PROP" {
            do { try readProp(c.data) } catch { warnings.append("Skipped a property: \(error.localizedDescription)") }
        }
        for (inst, name, ref) in pendingRefs {
            inst.props[name] = .ref(ref < 0 ? nil : instances[ref])
        }
        var roots: [Instance] = []
        for c in chunks where c.name == "PRNT" { try readPrnt(c.data, &roots) }
        let known: Set<String> = ["META", "SSTR", "INST", "PROP", "PRNT", "END", "SIGN"]
        for c in chunks where !known.contains(c.name) { warnings.append("Ignored unknown chunk \(c.name)") }
        return RbxDocument(roots: roots, meta: meta, warnings: warnings)
    }

    private func decompress(_ off: Int, _ len: Int, _ out: Int) throws -> [UInt8] {
        let isZstd = len >= 4 && data[off] == 0x28 && data[off + 1] == 0xB5 && data[off + 2] == 0x2F && data[off + 3] == 0xFD
        return isZstd ? try ChunkCodec.zstd(data, off, len, out) : try ChunkCodec.lz4(data, off, len, out)
    }

    private func readMeta(_ d: [UInt8]) throws {
        var r = ByteReader(d)
        let n = Int(try r.i32())
        for _ in 0..<max(0, n) { let k = try r.string(); meta[k] = try r.string() }
    }

    private func readSstr(_ d: [UInt8]) throws {
        var r = ByteReader(d)
        _ = try r.i32()
        let n = Int(try r.i32())
        for _ in 0..<max(0, n) { try r.skip(16); sharedStrings.append(Data(try r.stringBytes())) }
    }

    private func readInst(_ d: [UInt8]) throws {
        var r = ByteReader(d)
        let classId = try r.i32()
        let cls = try r.string()
        let format = try r.u8()
        let n = Int(try r.i32())
        let refs = try r.refArray(n)
        let isService = format == 1
        if isService { try r.skip(n) }
        classes[classId] = ClassInfo(name: cls, refs: refs)
        for ref in refs {
            let inst = Instance(cls)
            inst.isService = isService
            inst.loadedRef = Int(ref)
            instances[ref] = inst
        }
    }

    private func readPrnt(_ d: [UInt8], _ roots: inout [Instance]) throws {
        var r = ByteReader(d)
        _ = try r.u8()
        let n = Int(try r.i32())
        let kids = try r.refArray(n), parents = try r.refArray(n)
        for i in 0..<n {
            guard let c = instances[kids[i]] else { continue }
            if parents[i] >= 0, let p = instances[parents[i]] { c.attachRaw(p) } else { roots.append(c) }
        }
    }

    private func readProp(_ d: [UInt8]) throws {
        var r = ByteReader(d)
        let classId = try r.i32()
        let name = try r.string()
        let type = try r.u8()
        guard let ci = classes[classId] else { return }
        let insts = ci.refs.compactMap { instances[$0] }
        let n = insts.count
        let payloadStart = r.pos
        do {
            let values = try readValues(&r, type, n, insts, name)
            for i in 0..<n {
                if type != PropType.REF { insts[i].props[name] = values[i] }
                insts[i].propTypes[name] = type
            }
        } catch {
            let payload = Data(d[payloadStart...])
            warnings.append("Preserved \(ci.name).\(name) (unsupported type 0x\(String(type, radix: 16)))")
            for i in 0..<n {
                insts[i].props[name] = .raw(RawPropValue(type: type, payload: payload, index: i, count: n))
                insts[i].propTypes[name] = type
            }
        }
    }

    private static let normals: [Vector3] = [Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, -Vector3.xAxis, -Vector3.yAxis, -Vector3.zAxis]
    static func rotationFromId(_ id: Int) -> CFrame {
        let v = id - 1
        let r = normals[(v / 6) % 6], u = normals[v % 6]
        return CFrame.fromColumns(.zero, r, u, r.cross(u))
    }

    private func readCFrames(_ r: inout ByteReader, _ n: Int) throws -> [CFrame] {
        var rots: [CFrame] = []
        rots.reserveCapacity(n)
        for _ in 0..<n {
            let id = try r.u8()
            if id != 0 {
                rots.append(RbxBinaryReader.rotationFromId(id))
            } else {
                var m = [Float](repeating: 0, count: 9)
                for k in 0..<9 { m[k] = try r.f32() }
                rots.append(CFrame(0, 0, 0, m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8]))
            }
        }
        let xs = try r.f32Array(n), ys = try r.f32Array(n), zs = try r.f32Array(n)
        return (0..<n).map { rots[$0].withPosition(Vector3(xs[$0], ys[$0], zs[$0])) }
    }

    private func readValues(_ r: inout ByteReader, _ type: Int, _ n: Int, _ insts: [Instance], _ name: String) throws -> [PropValue] {
        switch type {
        case PropType.STRING:
            return try (0..<n).map { _ in
                let b = try r.stringBytes()
                if let s = String(bytes: b, encoding: .utf8) { return .string(s) }
                return .binaryString(BinaryString(Data(b)))
            }
        case PropType.BOOL: return try (0..<n).map { _ in .bool(try r.u8() != 0) }
        case PropType.INT: return try r.i32Array(n).map { .int($0) }
        case PropType.FLOAT: return try r.f32Array(n).map { .float($0) }
        case PropType.DOUBLE: return try (0..<n).map { _ in .double(try r.f64()) }
        case PropType.UDIM:
            let s = try r.f32Array(n), o = try r.i32Array(n)
            return (0..<n).map { .udim(UDim(s[$0], o[$0])) }
        case PropType.UDIM2:
            let xs = try r.f32Array(n), ys = try r.f32Array(n), xo = try r.i32Array(n), yo = try r.i32Array(n)
            return (0..<n).map { .udim2(UDim2(xs[$0], xo[$0], ys[$0], yo[$0])) }
        case PropType.RAY:
            return try (0..<n).map { _ in
                .ray(Ray(Vector3(try r.f32(), try r.f32(), try r.f32()), Vector3(try r.f32(), try r.f32(), try r.f32())))
            }
        case PropType.FACES: return try (0..<n).map { _ in .faces(Faces(UInt8(try r.u8()))) }
        case PropType.AXES: return try (0..<n).map { _ in .axes(Axes(UInt8(try r.u8()))) }
        case PropType.BRICKCOLOR: return try r.u32Array(n).map { .brickColor(BrickColorV(Int32(bitPattern: $0))) }
        case PropType.COLOR3:
            let a = try r.f32Array(n), b = try r.f32Array(n), c = try r.f32Array(n)
            return (0..<n).map { .color3(Color3(a[$0], b[$0], c[$0])) }
        case PropType.VECTOR2:
            let a = try r.f32Array(n), b = try r.f32Array(n)
            return (0..<n).map { .vector2(Vector2(a[$0], b[$0])) }
        case PropType.VECTOR3:
            let a = try r.f32Array(n), b = try r.f32Array(n), c = try r.f32Array(n)
            return (0..<n).map { .vector3(Vector3(a[$0], b[$0], c[$0])) }
        case PropType.CFRAME: return try readCFrames(&r, n).map { .cframe($0) }
        case PropType.ENUM: return try r.u32Array(n).map { .enumValue(EnumValue($0)) }
        case PropType.REF:
            let refs = try r.refArray(n)
            for i in 0..<n { pendingRefs.append((insts[i], name, refs[i])) }
            return Array(repeating: .ref(nil), count: n)
        case PropType.VECTOR3INT16:
            func s16() throws -> Int16 { Int16(truncatingIfNeeded: try r.u16()) }
            return try (0..<n).map { _ in .vector3int16(Vector3int16(try s16(), try s16(), try s16())) }
        case PropType.NUMBERSEQ:
            return try (0..<n).map { _ in
                let k = Int(try r.i32())
                return .numberSequence(NumberSequence(try (0..<max(0, k)).map { _ in NumberKey(try r.f32(), try r.f32(), try r.f32()) }))
            }
        case PropType.COLORSEQ:
            return try (0..<n).map { _ in
                let k = Int(try r.i32())
                return .colorSequence(ColorSequence(try (0..<max(0, k)).map { _ in
                    ColorKey(try r.f32(), Color3(try r.f32(), try r.f32(), try r.f32()), try r.f32())
                }))
            }
        case PropType.NUMBERRANGE: return try (0..<n).map { _ in .numberRange(NumberRange(try r.f32(), try r.f32())) }
        case PropType.RECT:
            let a = try r.f32Array(n), b = try r.f32Array(n), c = try r.f32Array(n), e = try r.f32Array(n)
            return (0..<n).map { .rect(Rect(a[$0], b[$0], c[$0], e[$0])) }
        case PropType.PHYSPROPS:
            return try (0..<n).map { _ in
                let f = UInt8(try r.u8())
                guard f & 1 != 0 else { return .physicalProps(PhysicalProps(flags: f)) }
                var p = PhysicalProps(flags: f, density: try r.f32(), friction: try r.f32(), elasticity: try r.f32(),
                                      frictionWeight: try r.f32(), elasticityWeight: try r.f32())
                if f & 2 != 0 { p.acoustic = try r.f32() }
                return .physicalProps(p)
            }
        case PropType.COLOR3U8:
            let a = try r.bytes(n), b = try r.bytes(n), c = try r.bytes(n)
            return (0..<n).map { .color3(.fromRGB(Int(a[$0]), Int(b[$0]), Int(c[$0]))) }
        case PropType.INT64: return try r.i64Array(n).map { .int64($0) }
        case PropType.SHAREDSTRING:
            return try r.u32Array(n).map { i in
                let k = Int(i)
                return .sharedString(SharedStr(k < sharedStrings.count ? sharedStrings[k] : Data()))
            }
        case PropType.OPTCFRAME:
            _ = try r.u8()
            let cfs = try readCFrames(&r, n)
            _ = try r.u8()
            let has = try (0..<n).map { _ in try r.u8() != 0 }
            return (0..<n).map { .optionalCFrame(OptionalCFrame(has[$0] ? cfs[$0] : nil)) }
        case PropType.UNIQUEID:
            let d = try r.interleaved(n, 16)
            return (0..<n).map { .uniqueId(UniqueId(Data(d[$0 * 16..<$0 * 16 + 16]))) }
        case PropType.FONT:
            return try (0..<n).map { _ in .font(FontValue(try r.string(), try r.u16(), try r.u8(), try r.string())) }
        case PropType.SECCAPS:
            let d = try r.interleaved(n, 8)
            return (0..<n).map { i in
                var v: UInt64 = 0
                for b in 0..<8 { v = v << 8 | UInt64(d[i * 8 + b]) }
                return .securityCaps(SecurityCaps(v))
            }
        case PropType.CONTENT:
            let types = try r.i32Array(n)
            let uriCount = Int(try r.i32())
            let uris = try (0..<max(0, uriCount)).map { _ in try r.string() }
            let objCount = Int(try r.i32())
            let objs = try r.refArray(objCount)
            let ext = Int(try r.i32())
            if ext != 0 { _ = try r.refArray(ext) }
            var ui = 0, oi = 0
            return types.map { t in
                switch t {
                case 1:
                    defer { ui += 1 }
                    return .content(ContentValue(sourceType: 1, uri: ui < uris.count ? uris[ui] : ""))
                case 2:
                    defer { oi += 1 }
                    let ref = oi < objs.count ? objs[oi] : -1
                    return .content(ContentValue(sourceType: 2, uri: "", obj: ref < 0 ? nil : instances[ref]))
                default:
                    return .content(ContentValue())
                }
            }
        default:
            throw RbxFormatError("unsupported type 0x\(String(type, radix: 16)) for '\(name)'")
        }
    }
}
