import Foundation
import CryptoKit

/// Writer for the binary format (port of format/RbxBinaryWriter.kt). Chunks are written uncompressed,
/// exactly like the Android app does.
public enum RbxBinaryWriter {
    public static func write(_ roots: [Instance], meta: OrderedDict<String>) -> Data {
        var all: [Instance] = []
        func collect(_ i: Instance) {
            guard i.archivable else { return }
            all.append(i)
            for c in i.children { collect(c) }
        }
        roots.forEach(collect)

        // Referent ids: keep the ids from the loaded file when possible.
        var ref: [ObjectIdentifier: Int32] = [:]
        var used = Set<Int>()
        for i in all where i.loadedRef >= 0 && used.insert(i.loadedRef).inserted {
            ref[ObjectIdentifier(i)] = Int32(i.loadedRef)
        }
        var next = Int32((used.max() ?? -1) + 1)
        for i in all where ref[ObjectIdentifier(i)] == nil { ref[ObjectIdentifier(i)] = next; next += 1 }

        var byClass: [String: [Instance]] = [:]
        for i in all { byClass[i.className, default: []].append(i) }
        let classNames = byClass.keys.sorted()

        // Shared strings, deduplicated by content.
        var sstr: [Data: Int] = [:]
        var sstrOrder: [Data] = []
        for i in all {
            for v in i.props.values { if case .sharedString(let s) = v, sstr[s.bytes] == nil { sstr[s.bytes] = sstrOrder.count; sstrOrder.append(s.bytes) } }
        }

        var file = ByteWriter()
        file.bytes(Array("<roblox!".utf8))
        file.bytes([0x89, 0xFF, 0x0D, 0x0A, 0x1A, 0x0A])
        file.u16(0)
        file.i32(classNames.count)
        file.i32(all.count)
        file.bytes([UInt8](repeating: 0, count: 8))

        func chunk(_ name: String, _ body: [UInt8]) {
            var nb = Array(name.utf8.prefix(4))
            while nb.count < 4 { nb.append(0) }
            file.bytes(nb)
            file.i32(0)
            file.i32(body.count)
            file.i32(0)
            file.bytes(body)
        }

        if !meta.isEmpty {
            var w = ByteWriter()
            w.i32(meta.count)
            for (k, v) in meta { w.string(k); w.string(v) }
            chunk("META", w.out)
        }
        if !sstrOrder.isEmpty {
            var w = ByteWriter()
            w.i32(0)
            w.i32(sstrOrder.count)
            for s in sstrOrder { w.bytes(Array(Insecure.MD5.hash(data: s))); w.string(s) }
            chunk("SSTR", w.out)
        }

        for (idx, cls) in classNames.enumerated() {
            let list = byClass[cls]!
            var w = ByteWriter()
            w.i32(idx)
            w.string(cls)
            let service = list.contains { $0.isService }
            w.u8(service ? 1 : 0)
            w.i32(list.count)
            w.refArray(list.map { ref[ObjectIdentifier($0)]! })
            if service { for _ in list { w.u8(1) } }
            chunk("INST", w.out)
        }

        for (idx, cls) in classNames.enumerated() {
            let list = byClass[cls]!
            var names: [String] = ["Name"]
            var seen: Set<String> = ["Name"]
            for i in list { for k in i.props.keys where seen.insert(k).inserted { names.append(k) } }

            for prop in names {
                // Unsupported values we loaded verbatim: write them back only if untouched.
                if let raw = list.lazy.compactMap({ i -> RawPropValue? in if case .raw(let r)? = i.props[prop] { return r }; return nil }).first {
                    let intact = raw.count == list.count && list.enumerated().allSatisfy { (n, i) in
                        if case .raw(let r)? = i.props[prop] { return r.payload == raw.payload && r.index == n }
                        return false
                    }
                    if intact {
                        var w = ByteWriter()
                        w.i32(idx); w.string(prop); w.u8(raw.type); w.bytes([UInt8](raw.payload))
                        chunk("PROP", w.out)
                    }
                    continue
                }
                let type = list.lazy.compactMap { $0.propTypes[prop] }.first
                    ?? list.first(where: { $0.props.contains(prop) }).map { PropType.infer($0.props[prop]!) }
                    ?? PropType.STRING
                let vals: [PropValue] = list.map { i in
                    if prop == "Name" { return .string(i.name) }
                    return i.props[prop] ?? PropType.defaultValue(type)
                }
                var w = ByteWriter()
                w.i32(idx); w.string(prop); w.u8(type)
                writeValues(&w, type, vals, ref, sstr)
                chunk("PROP", w.out)
            }
        }

        var p = ByteWriter()
        p.u8(0)
        p.i32(all.count)
        p.refArray(all.map { ref[ObjectIdentifier($0)]! })
        p.refArray(all.map { i in i.parent.flatMap { ref[ObjectIdentifier($0)] } ?? -1 })
        chunk("PRNT", p.out)
        chunk("END", Array("</roblox>".utf8))
        return Data(file.out)
    }

    // MARK: value coercion (values may not match the declared type after edits)

    private static func f(_ v: PropValue) -> Float { v.asFloat ?? 0 }
    private static func i(_ v: PropValue) -> Int32 {
        switch v {
        case .int(let x): return x
        case .int64(let x): return Int32(truncatingIfNeeded: x)
        case .float(let x): return Int32(x)
        case .double(let x): return Int32(x)
        case .enumValue(let e): return Int32(bitPattern: e.value)
        case .brickColor(let b): return b.number
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }
    private static func v3(_ v: PropValue) -> Vector3 { v.asVector3 ?? .zero }
    private static func c3(_ v: PropValue) -> Color3 {
        if case .brickColor(let b) = v { return b.color }
        return v.asColor3 ?? Color3(0, 0, 0)
    }
    private static func cf(_ v: PropValue) -> CFrame { v.asCFrame ?? .identity }
    private static func b8(_ x: Float) -> UInt8 { UInt8(Swift.min(1, Swift.max(0, x)) * 255 + 0.5) }

    private static func writeCFrames(_ w: inout ByteWriter, _ cfs: [CFrame]) {
        for c in cfs {
            w.u8(0)
            for x in [c.r00, c.r01, c.r02, c.r10, c.r11, c.r12, c.r20, c.r21, c.r22] { w.f32(x) }
        }
        w.f32Array(cfs.map(\.x)); w.f32Array(cfs.map(\.y)); w.f32Array(cfs.map(\.z))
    }

    private static func writeValues(_ w: inout ByteWriter, _ type: Int, _ vals: [PropValue],
                                    _ ref: [ObjectIdentifier: Int32], _ sstr: [Data: Int]) {
        let n = vals.count
        switch type {
        case PropType.STRING:
            for v in vals {
                switch v {
                case .binaryString(let b): w.string(b.bytes)
                case .content(let c): w.string(c.uri)
                case .ref(nil): w.string("")
                default: w.string(v.description)
                }
            }
        case PropType.BOOL: for v in vals { w.u8(v.asBool == true ? 1 : 0) }
        case PropType.INT: w.i32Array(vals.map(i))
        case PropType.FLOAT: w.f32Array(vals.map(f))
        case PropType.DOUBLE:
            for v in vals { if case .double(let d) = v { w.f64(d) } else { w.f64(Double(f(v))) } }
        case PropType.UDIM:
            let u = vals.map { v -> UDim in if case .udim(let x) = v { return x }; return UDim(0, 0) }
            w.f32Array(u.map(\.scale)); w.i32Array(u.map(\.offset))
        case PropType.UDIM2:
            let u = vals.map { v -> UDim2 in if case .udim2(let x) = v { return x }; return UDim2(0, 0, 0, 0) }
            w.f32Array(u.map(\.x.scale)); w.f32Array(u.map(\.y.scale)); w.i32Array(u.map(\.x.offset)); w.i32Array(u.map(\.y.offset))
        case PropType.RAY:
            for v in vals {
                let r: Ray = { if case .ray(let x) = v { return x }; return Ray(.zero, .zero) }()
                for x in [r.origin.x, r.origin.y, r.origin.z, r.direction.x, r.direction.y, r.direction.z] { w.f32(x) }
            }
        case PropType.FACES: for v in vals { if case .faces(let x) = v { w.u8(Int(x.bits)) } else { w.u8(0) } }
        case PropType.AXES: for v in vals { if case .axes(let x) = v { w.u8(Int(x.bits)) } else { w.u8(0) } }
        case PropType.BRICKCOLOR:
            w.u32Array(vals.map { v in
                if case .brickColor(let b) = v { return UInt32(bitPattern: b.number) }
                if let c = v.asColor3 { return UInt32(BrickColors.closest(c)) }
                return UInt32(bitPattern: i(v))
            })
        case PropType.COLOR3:
            let c = vals.map(c3)
            w.f32Array(c.map(\.r)); w.f32Array(c.map(\.g)); w.f32Array(c.map(\.b))
        case PropType.VECTOR2:
            let v = vals.map { x -> Vector2 in if case .vector2(let y) = x { return y }; return .zero }
            w.f32Array(v.map(\.x)); w.f32Array(v.map(\.y))
        case PropType.VECTOR3:
            let v = vals.map(v3)
            w.f32Array(v.map(\.x)); w.f32Array(v.map(\.y)); w.f32Array(v.map(\.z))
        case PropType.CFRAME: writeCFrames(&w, vals.map(cf))
        case PropType.ENUM: w.u32Array(vals.map { UInt32(bitPattern: i($0)) })
        case PropType.REF:
            w.refArray(vals.map { v in if case .ref(let t?) = v, let id = ref[ObjectIdentifier(t)] { return id }; return -1 })
        case PropType.VECTOR3INT16:
            for v in vals {
                let x: Vector3int16 = { if case .vector3int16(let y) = v { return y }; return Vector3int16(0, 0, 0) }()
                w.u16(Int(UInt16(bitPattern: x.x))); w.u16(Int(UInt16(bitPattern: x.y))); w.u16(Int(UInt16(bitPattern: x.z)))
            }
        case PropType.NUMBERSEQ:
            for v in vals {
                let keys: [NumberKey] = { if case .numberSequence(let s) = v { return s.keys }; return [NumberKey(0, 0, 0), NumberKey(1, 0, 0)] }()
                w.i32(keys.count)
                for k in keys { w.f32(k.time); w.f32(k.value); w.f32(k.envelope) }
            }
        case PropType.COLORSEQ:
            for v in vals {
                let keys: [ColorKey] = { if case .colorSequence(let s) = v { return s.keys }; return [ColorKey(0, Color3(1, 1, 1), 0), ColorKey(1, Color3(1, 1, 1), 0)] }()
                w.i32(keys.count)
                for k in keys { w.f32(k.time); w.f32(k.color.r); w.f32(k.color.g); w.f32(k.color.b); w.f32(k.envelope) }
            }
        case PropType.NUMBERRANGE:
            for v in vals {
                if case .numberRange(let r) = v { w.f32(r.min); w.f32(r.max) } else { let x = f(v); w.f32(x); w.f32(x) }
            }
        case PropType.RECT:
            let r = vals.map { v -> Rect in if case .rect(let x) = v { return x }; return Rect(0, 0, 0, 0) }
            w.f32Array(r.map(\.minX)); w.f32Array(r.map(\.minY)); w.f32Array(r.map(\.maxX)); w.f32Array(r.map(\.maxY))
        case PropType.PHYSPROPS:
            for v in vals {
                guard case .physicalProps(let p) = v, p.isCustom else { w.u8(0); continue }
                w.u8(Int(p.flags))
                for x in [p.density, p.friction, p.elasticity, p.frictionWeight, p.elasticityWeight] { w.f32(x) }
                if p.flags & 2 != 0 { w.f32(p.acoustic) }
            }
        case PropType.COLOR3U8:
            let c = vals.map(c3)
            w.bytes(c.map { b8($0.r) }); w.bytes(c.map { b8($0.g) }); w.bytes(c.map { b8($0.b) })
        case PropType.INT64:
            w.i64Array(vals.map { v in if case .int64(let x) = v { return x }; return Int64(i(v)) })
        case PropType.SHAREDSTRING:
            w.u32Array(vals.map { v in if case .sharedString(let s) = v, let k = sstr[s.bytes] { return UInt32(k) }; return 0 })
        case PropType.OPTCFRAME:
            let o = vals.map { v -> CFrame? in if case .optionalCFrame(let x) = v { return x.value }; return nil }
            w.u8(16)
            writeCFrames(&w, o.map { $0 ?? .identity })
            w.u8(2)
            for x in o { w.u8(x != nil ? 1 : 0) }
        case PropType.UNIQUEID:
            var d: [UInt8] = []
            for v in vals {
                var b = [UInt8](repeating: 0, count: 16)
                if case .uniqueId(let u) = v { for (k, x) in u.bytes.prefix(16).enumerated() { b[k] = x } }
                d += b
            }
            w.interleaved(d, n, 16)
        case PropType.FONT:
            for v in vals {
                let fv: FontValue = { if case .font(let x) = v { return x }; return .default }()
                w.string(fv.family); w.u16(fv.weight); w.u8(fv.style); w.string(fv.cachedFaceId)
            }
        case PropType.SECCAPS:
            var d: [UInt8] = []
            for v in vals {
                let bits: UInt64 = { if case .securityCaps(let s) = v { return s.bits }; return 0 }()
                for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8(truncatingIfNeeded: bits >> UInt64(s))) }
            }
            w.interleaved(d, n, 8)
        case PropType.CONTENT:
            let cs: [ContentValue] = vals.map { v in
                switch v {
                case .content(let c): return c
                case .string(let s): return s.isEmpty ? ContentValue() : ContentValue(sourceType: 1, uri: s)
                default: return ContentValue()
                }
            }
            w.i32Array(cs.map { c in Int32(c.sourceType == 2 && c.obj == nil ? 0 : c.sourceType) })
            let uris = cs.filter { $0.sourceType == 1 }
            w.i32(uris.count)
            for c in uris { w.string(c.uri) }
            let objs = cs.filter { $0.sourceType == 2 && $0.obj != nil }
            w.i32(objs.count)
            w.refArray(objs.map { c in ref[ObjectIdentifier(c.obj!)] ?? -1 })
            w.i32(0)
        default:
            // Unknown type id: fall back to strings so the file stays loadable.
            for v in vals { w.string(v.description) }
        }
    }
}
