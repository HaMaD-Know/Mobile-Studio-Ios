import Foundation

/// Draco decoder for the sequential triangle meshes Roblox stores in v7 `.mesh` files
/// (port of render/Draco.kt: sequential connectivity, rANS symbols, delta/wrap and octahedral
/// normal prediction, quantization). Edgebreaker meshes are rejected, as in the Android app.
enum Draco {
    struct Attribute {
        let type: Int          // 0 position, 1 normal, 2 color, 3 texcoord, 4 generic
        let dataType: Int
        let components: Int
        let normalized: Bool
        var values: [Float] = []
    }

    struct Mesh {
        let numPoints: Int
        let faces: [Int]
        let attributes: [Attribute]
        func attribute(_ type: Int) -> Attribute? { attributes.first { $0.type == type } }
    }

    static func isDraco(_ b: [UInt8], _ off: Int) -> Bool {
        b.count >= off + 5 && Array(b[off..<off + 5]) == Array("DRACO".utf8)
    }

    struct Reader {
        let b: [UInt8]
        var pos: Int
        let end: Int
        var remaining: Int { end - pos }
        func need(_ n: Int) throws { if n < 0 || pos + n > end { throw MeshError("Draco: unexpected end of data") } }
        mutating func u8() throws -> Int { try need(1); defer { pos += 1 }; return Int(b[pos]) }
        mutating func i8() throws -> Int { try need(1); defer { pos += 1 }; return Int(Int8(bitPattern: b[pos])) }
        mutating func u16() throws -> Int { try need(2); defer { pos += 2 }; return Int(b[pos]) | Int(b[pos + 1]) << 8 }
        mutating func i32() throws -> Int {
            try need(4); defer { pos += 4 }
            return Int(Int32(bitPattern: UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24))
        }
        mutating func f32() throws -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: try i32())) }
        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while shift <= 63 {
                let v = try u8()
                result |= UInt64(v & 127) << shift
                if v & 128 == 0 { return result }
                shift += 7
            }
            throw MeshError("Draco: bad varint")
        }
        mutating func varintInt() throws -> Int {
            let v = try varint()
            guard v <= UInt64(Int32.max) else { throw MeshError("Draco: value out of range") }
            return Int(v)
        }
        mutating func skip(_ n: Int) throws { try need(n); pos += n }
    }

    struct BitReader {
        let b: [UInt8], start: Int, end: Int
        var bit = 0
        mutating func get(_ n: Int) -> Int {
            var v = 0
            for i in 0..<n {
                let idx = start + (bit >> 3)
                let x = idx < end ? (Int(b[idx]) >> (bit & 7)) & 1 : 0
                bit += 1
                v |= x << i
            }
            return v
        }
        var bytesUsed: Int { (bit + 7) / 8 }
    }

    final class RAns {
        let precision: Int
        let lBase: UInt64
        var lut: [Int]
        let prob: [UInt64]
        var cum: [UInt64]
        var buf: [UInt8] = []
        var start = 0
        var offset = 0
        var state: UInt64 = 0

        init(precisionBits: Int, probs: [Int]) throws {
            precision = 1 << precisionBits
            lBase = UInt64(precision) * 4
            lut = [Int](repeating: 0, count: precision)
            prob = probs.map { UInt64(UInt32(truncatingIfNeeded: $0)) }
            cum = [UInt64](repeating: 0, count: probs.count)
            var c: UInt64 = 0
            var act = 0
            for i in 0..<probs.count {
                cum[i] = c
                c += prob[i]
                guard c <= UInt64(precision) else { throw MeshError("Draco: bad probability table") }
                for j in act..<Int(c) { lut[j] = i }
                act = Int(c)
            }
            guard c == UInt64(precision) else { throw MeshError("Draco: bad probability table") }
        }

        func initData(_ b: [UInt8], _ s: Int, _ len: Int) throws {
            guard len >= 1 else { throw MeshError("Draco: empty rANS data") }
            buf = b; start = s
            func le(_ at: Int, _ n: Int) -> UInt64 {
                var v: UInt64 = 0
                for k in 0..<n { v |= UInt64(b[s + at + k]) << UInt64(k * 8) }
                return v
            }
            let last = Int(b[s + len - 1])
            switch last >> 6 {
            case 0: offset = len - 1; state = UInt64(last & 63)
            case 1:
                guard len >= 2 else { throw MeshError("Draco: bad rANS data") }
                offset = len - 2; state = le(len - 2, 2) & 0x3FFF
            case 2:
                guard len >= 3 else { throw MeshError("Draco: bad rANS data") }
                offset = len - 3; state = le(len - 3, 3) & 0x3FFFFF
            default:
                guard len >= 4 else { throw MeshError("Draco: bad rANS data") }
                offset = len - 4; state = le(len - 4, 4) & 0x3FFFFFFF
            }
            state += lBase
            guard state < lBase * 256 else { throw MeshError("Draco: bad rANS state") }
        }

        func read() -> Int {
            while state < lBase && offset > 0 {
                offset -= 1
                state = state * 256 + UInt64(buf[start + offset])
            }
            let quo = state / UInt64(precision)
            let rem = Int(state % UInt64(precision))
            let sym = lut[rem]
            state = prob[sym] * quo + UInt64(rem) - cum[sym]
            return sym
        }
    }

    struct SymbolDecoder {
        let numSymbols: Int
        let ans: RAns?
        func start(_ r: inout Reader) throws {
            let bytes = try r.varint()
            guard bytes <= UInt64(r.remaining), let ans else { throw MeshError("Draco: bad rANS size") }
            try ans.initData(r.b, r.pos, Int(bytes))
            r.pos += Int(bytes)
        }
        func read() -> Int { ans!.read() }
    }

    static func precisionFor(_ bits: Int) -> Int { min(20, max(12, bits * 3 / 2)) }

    static func createSymbolDecoder(_ r: inout Reader, _ uniqueSymbolBits: Int) throws -> SymbolDecoder {
        let num = try r.varintInt()
        guard num / 64 <= r.remaining else { throw MeshError("Draco: too many symbols") }
        if num == 0 { return SymbolDecoder(numSymbols: 0, ans: nil) }
        var probs = [Int](repeating: 0, count: num)
        var i = 0
        while i < num {
            let data = try r.u8()
            let token = data & 3
            if token == 3 {
                let run = data >> 2
                guard i + run < num else { throw MeshError("Draco: bad probability run") }
                i += run + 1
            } else {
                var p = data >> 2
                for k in 0..<token { p |= (try r.u8()) << ((k + 1) * 8 - 2) }
                probs[i] = p
                i += 1
            }
        }
        return SymbolDecoder(numSymbols: num, ans: try RAns(precisionBits: precisionFor(uniqueSymbolBits), probs: probs))
    }

    static func decodeSymbols(_ n: Int, _ comps: Int, _ r: inout Reader) throws -> [Int] {
        var out = [Int](repeating: 0, count: n)
        if n == 0 { return out }
        switch try r.u8() {
        case 0:
            let tags = try createSymbolDecoder(&r, 5)
            try tags.start(&r)
            guard tags.numSymbols > 0 else { throw MeshError("Draco: no tag symbols") }
            var bits = BitReader(b: r.b, start: r.pos, end: r.end)
            var id = 0, i = 0
            while i < n {
                let len = tags.read()
                guard len <= 32 else { throw MeshError("Draco: bad tag") }
                var j = 0
                while j < comps && id < n { out[id] = bits.get(len); j += 1; id += 1 }
                i += comps
            }
            r.pos += bits.bytesUsed
            try r.need(0)
        case 1:
            let maxBits = try r.u8()
            guard (1...18).contains(maxBits) else { throw MeshError("Draco: bad symbol bit length \(maxBits)") }
            let dec = try createSymbolDecoder(&r, maxBits)
            guard dec.numSymbols > 0 else { throw MeshError("Draco: no symbols") }
            try dec.start(&r)
            for i in 0..<n { out[i] = dec.read() }
        default:
            throw MeshError("Draco: unknown symbol coding")
        }
        return out
    }

    /// Octahedral normal coding helpers.
    struct Octa {
        let maxQ: Int, maxValue: Int, center: Int
        let scale: Float
        init(_ bits: Int) throws {
            guard (2...30).contains(bits) else { throw MeshError("Draco: bad normal quantization") }
            maxQ = (1 << bits) - 1
            maxValue = maxQ - 1
            center = maxValue / 2
            scale = 2 / Float(maxValue)
        }
        func isInDiamond(_ s: Int, _ t: Int) -> Bool { abs(s) + abs(t) <= center }
        func invertDiamond(_ p: inout (Int, Int)) {
            let (s, t) = p
            var signS: Int, signT: Int
            if s >= 0 && t >= 0 { signS = 1; signT = 1 }
            else if s <= 0 && t <= 0 { signS = -1; signT = -1 }
            else { signS = s > 0 ? 1 : -1; signT = t > 0 ? 1 : -1 }
            let cs = center * signS, ct = center * signT
            let us2 = s + s - cs, ut2 = t + t - ct
            let (us, ut) = signS * signT >= 0 ? (-ut2, -us2) : (ut2, us2)
            p = ((us + cs) / 2, (ut + ct) / 2)
        }
        func modMax(_ x: Int) -> Int { x > center ? x - maxQ : (x < -center ? x + maxQ : x) }
        func toUnit(_ si: Int, _ ti: Int) -> (Float, Float, Float) {
            let y0 = Float(si) * scale - 1, z0 = Float(ti) * scale - 1
            let x = 1 - abs(y0) - abs(z0)
            let xo = max(0, -x)
            let y = y0 + (y0 < 0 ? xo : -xo), z = z0 + (z0 < 0 ? xo : -xo)
            let n2 = x * x + y * y + z * z
            guard n2 >= 1e-6 else { return (0, 0, 0) }
            let d = 1 / n2.squareRoot()
            return (x * d, y * d, z * d)
        }
    }

    static func rotationCount(_ x: Int, _ y: Int) -> Int {
        if x == 0 { return y == 0 ? 0 : (y > 0 ? 3 : 1) }
        if x > 0 { return y >= 0 ? 2 : 1 }
        return y <= 0 ? 0 : 3
    }
    static func rotate(_ p: inout (Int, Int), _ count: Int) {
        let (x, y) = p
        switch count {
        case 1: p = (y, -x)
        case 2: p = (-x, -y)
        case 3: p = (-y, x)
        default: break
        }
    }

    /// Attribute + its sequential decoder kind (0 generic, 1 integer, 2 quantized, 3 normals).
    final class AttDecoder {
        var att: Attribute
        let kind: Int
        var portable: [Int] = []
        var minValues: [Float] = []
        var range: Float = 0
        var qBits = 0
        var octBits = 0
        init(_ a: Attribute, _ k: Int) { att = a; kind = k }
    }

    static func readTyped(_ r: inout Reader, _ dt: Int) throws -> Float {
        switch dt {
        case 1: return Float(try r.i8())
        case 2, 11: return Float(try r.u8())
        case 3: return Float(Int16(truncatingIfNeeded: try r.u16()))
        case 4: return Float(try r.u16())
        case 5: return Float(try r.i32())
        case 6: return Float(UInt32(truncatingIfNeeded: try r.i32()))
        case 7, 8:
            let lo = UInt64(UInt32(truncatingIfNeeded: try r.i32())), hi = UInt64(UInt32(truncatingIfNeeded: try r.i32()))
            return Float(Int64(bitPattern: hi << 32 | lo))
        case 9: return try r.f32()
        case 10:
            let lo = UInt64(UInt32(truncatingIfNeeded: try r.i32())), hi = UInt64(UInt32(truncatingIfNeeded: try r.i32()))
            return Float(Double(bitPattern: hi << 32 | lo))
        default: throw MeshError("Draco: bad data type \(dt)")
        }
    }

    static func decodePortable(_ d: AttDecoder, _ n: Int, _ r: inout Reader) throws {
        if d.kind == 0 {
            d.att.values = try (0..<(d.att.components * n)).map { _ in try readTyped(&r, d.att.dataType) }
            return
        }
        let comps = d.kind == 3 ? 2 : d.att.components
        let method = try r.i8()
        var transform = -1
        if method != -2 {
            guard (-2...6).contains(method) else { throw MeshError("Draco: bad prediction method \(method)") }
            transform = try r.i8()
            guard (-1...3).contains(transform) else { throw MeshError("Draco: bad prediction transform \(transform)") }
        }
        let predicted = method != -2
        let total = n * comps
        var values: [Int]
        if try r.u8() > 0 {
            values = try decodeSymbols(total, comps, &r)
        } else {
            let nb = try r.u8()
            guard (1...4).contains(nb) else { throw MeshError("Draco: bad raw integer size") }
            try r.need(nb * total)
            values = [Int](repeating: 0, count: total)
            for i in 0..<total {
                var v = 0
                for k in 0..<nb { v |= (try r.u8()) << (k * 8) }
                values[i] = v
            }
        }
        // Corrections are zig-zag coded unless the normal transform keeps them positive.
        if !(predicted && d.kind == 3) {
            for i in 0..<values.count { let u = values[i]; values[i] = (u >> 1) ^ -(u & 1) }
        }
        if predicted {
            if d.kind == 3 {
                let maxQ = try r.i32()
                if transform == 3 { _ = try r.i32() }
                guard maxQ > 0, maxQ % 2 == 1 else { throw MeshError("Draco: bad normal transform data") }
                let bits = Int.bitWidth - maxQ.leadingZeroBitCount
                let oct = try Octa(bits)
                var i = 0
                while i < total {
                    var pred = i == 0 ? (0, 0) : (values[i - 2], values[i - 1])
                    pred.0 -= oct.center; pred.1 -= oct.center
                    let inDiamond = oct.isInDiamond(pred.0, pred.1)
                    if !inDiamond { oct.invertDiamond(&pred) }
                    var orig: (Int, Int)
                    if transform == 3 {
                        let skipRotation = (pred.0 == 0 && pred.1 == 0) || (pred.0 < 0 && pred.1 <= 0)
                        let rot = rotationCount(pred.0, pred.1)
                        if !skipRotation { rotate(&pred, rot) }
                        orig = (oct.modMax(pred.0 + values[i]), oct.modMax(pred.1 + values[i + 1]))
                        if !skipRotation { rotate(&orig, (4 - rot) % 4) }
                    } else {
                        orig = (oct.modMax(pred.0 + values[i]), oct.modMax(pred.1 + values[i + 1]))
                    }
                    if !inDiamond { oct.invertDiamond(&orig) }
                    values[i] = orig.0 + oct.center
                    values[i + 1] = orig.1 + oct.center
                    i += 2
                }
            } else {
                let mn = try r.i32(), mx = try r.i32()
                guard mn <= mx, mx - mn < Int(Int32.max) else { throw MeshError("Draco: bad wrap transform data") }
                let maxDif = 1 + mx - mn
                for i in 0..<total {
                    var p = i < comps ? 0 : values[i - comps]
                    p = min(mx, max(mn, p))
                    var o = values[i] + p
                    if o > mx { o -= maxDif } else if o < mn { o += maxDif }
                    values[i] = o
                }
            }
        }
        d.portable = values
    }

    static func decodeTransformData(_ d: AttDecoder, _ r: inout Reader) throws {
        switch d.kind {
        case 2:
            d.minValues = try (0..<d.att.components).map { _ in try r.f32() }
            d.range = try r.f32()
            d.qBits = try r.u8()
            guard (1...30).contains(d.qBits) else { throw MeshError("Draco: bad quantization") }
        case 3:
            d.octBits = try r.u8()
        default: break
        }
    }

    static func finish(_ d: AttDecoder, _ n: Int) throws {
        switch d.kind {
        case 1:
            d.att.values = d.portable.map(Float.init)
        case 2:
            let maxQ = (1 << d.qBits) - 1
            let delta = d.range / Float(maxQ)
            let c = d.att.components
            d.att.values = (0..<(n * c)).map { Float(d.portable[$0]) * delta + d.minValues[$0 % c] }
        case 3:
            let oct = try Octa(d.octBits)
            var out = [Float](repeating: 0, count: n * 3)
            for i in 0..<n {
                let (x, y, z) = oct.toUnit(d.portable[i * 2], d.portable[i * 2 + 1])
                out[i * 3] = x; out[i * 3 + 1] = y; out[i * 3 + 2] = z
            }
            d.att.values = out
        default: break
        }
    }

    static func skipMetadata(_ r: inout Reader, _ depth: Int = 0) throws {
        guard depth <= 32 else { throw MeshError("Draco: metadata too deep") }
        let entries = try r.varintInt()
        for _ in 0..<entries { try r.skip(try r.u8()); try r.skip(try r.varintInt()) }
        let subs = try r.varintInt()
        for _ in 0..<subs { try r.skip(try r.u8()); try skipMetadata(&r, depth + 1) }
    }

    static func decode(_ bytes: [UInt8], _ off: Int, _ len: Int) throws -> Mesh {
        var r = Reader(b: bytes, pos: off, end: min(bytes.count, off + len))
        guard isDraco(bytes, off) else { throw MeshError("not Draco data") }
        try r.skip(5)
        let major = try r.u8(), minor = try r.u8()
        let version = major * 256 + minor
        guard major == 2 else { throw MeshError("Draco version \(major).\(minor) isn't supported") }
        guard try r.u8() == 1 else { throw MeshError("Draco: not a triangle mesh") }
        guard try r.u8() == 0 else { throw MeshError("Draco edgebreaker meshes aren't supported") }
        let flags = try r.u16()
        if flags & 0x8000 != 0 {
            let attMeta = try r.varintInt()
            for _ in 0..<attMeta { _ = try r.varint(); try skipMetadata(&r) }
            try skipMetadata(&r)
        }
        let numFaces: Int, numPoints: Int
        if version < 514 { numFaces = try r.i32(); numPoints = try r.i32() } else { numFaces = try r.varintInt(); numPoints = try r.varintInt() }
        guard (0...20_000_000).contains(numFaces), numPoints >= 0 else { throw MeshError("Draco: bad counts") }
        var faces = [Int](repeating: 0, count: numFaces * 3)
        if try r.u8() == 0 {
            let enc = try decodeSymbols(numFaces * 3, 1, &r)
            var last = 0
            for (i, e) in enc.enumerated() {
                var diff = e >> 1
                if e & 1 != 0 {
                    guard diff <= last else { throw MeshError("Draco: bad index") }
                    diff = -diff
                }
                last += diff
                faces[i] = last
            }
        } else {
            for i in 0..<faces.count {
                if numPoints < 256 { faces[i] = try r.u8() }
                else if numPoints < 65536 { faces[i] = try r.u16() }
                else { faces[i] = numPoints >= 2_097_152 || version < 514 ? try r.i32() : try r.varintInt() }
            }
        }
        guard faces.allSatisfy({ $0 >= 0 && $0 < numPoints }) else { throw MeshError("Draco: face index out of range") }
        var groups: [[AttDecoder]] = []
        let nDec = try r.u8()
        for _ in 0..<nDec {
            let nAtt = version < 512 ? try r.i32() : try r.varintInt()
            guard nAtt > 0, nAtt <= r.remaining * 5 else { throw MeshError("Draco: bad attribute count") }
            var atts: [Attribute] = []
            for _ in 0..<nAtt {
                let type = try r.u8(), dt = try r.u8(), comps = try r.u8(), norm = try r.u8()
                guard dt != 0, dt <= 11, comps != 0 else { throw MeshError("Draco: bad attribute") }
                _ = version < 259 ? UInt64(try r.u16()) : try r.varint()
                atts.append(Attribute(type: type, dataType: dt, components: comps, normalized: norm > 0))
            }
            var decs: [AttDecoder] = []
            for a in atts {
                let k = try r.u8()
                guard k <= 3 else { throw MeshError("Draco: unknown attribute decoder \(k)") }
                if (k == 2 || k == 3) && a.dataType != 9 { throw MeshError("Draco: bad attribute type") }
                if k == 3 && a.components != 3 { throw MeshError("Draco: bad normal attribute") }
                decs.append(AttDecoder(a, k))
            }
            groups.append(decs)
        }
        for decs in groups {
            for d in decs { try decodePortable(d, numPoints, &r) }
            for d in decs { try decodeTransformData(d, &r) }
            for d in decs { try finish(d, numPoints) }
        }
        return Mesh(numPoints: numPoints, faces: faces, attributes: groups.flatMap { $0.map(\.att) })
    }
}
