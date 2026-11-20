import Foundation
import libzstd

public struct RbxFormatError: Error, LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Little-endian reader with Roblox's interleaved array encodings (port of format/ByteReader.kt).
struct ByteReader {
    let buf: [UInt8]
    var pos: Int
    let end: Int

    init(_ buf: [UInt8], pos: Int = 0, end: Int? = nil) { self.buf = buf; self.pos = pos; self.end = end ?? buf.count }

    var remaining: Int { end - pos }
    private func need(_ n: Int) throws { if n < 0 || pos + n > end { throw RbxFormatError("Unexpected end of chunk") } }

    mutating func u8() throws -> Int { try need(1); defer { pos += 1 }; return Int(buf[pos]) }
    mutating func u16() throws -> Int {
        try need(2); defer { pos += 2 }
        return Int(buf[pos]) | Int(buf[pos + 1]) << 8
    }
    mutating func i32() throws -> Int32 {
        try need(4); defer { pos += 4 }
        return Int32(bitPattern: UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16 | UInt32(buf[pos + 3]) << 24)
    }
    mutating func f32() throws -> Float { Float(bitPattern: UInt32(bitPattern: try i32())) }
    mutating func i64() throws -> Int64 {
        let lo = UInt64(UInt32(bitPattern: try i32())), hi = UInt64(UInt32(bitPattern: try i32()))
        return Int64(bitPattern: hi << 32 | lo)
    }
    mutating func f64() throws -> Double { Double(bitPattern: UInt64(bitPattern: try i64())) }
    mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n); defer { pos += n }
        return Array(buf[pos..<pos + n])
    }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }
    mutating func stringBytes() throws -> [UInt8] {
        let n = Int(try i32())
        if n < 0 { throw RbxFormatError("Bad string length") }
        return try bytes(n)
    }
    mutating func string() throws -> String { String(decoding: try stringBytes(), as: UTF8.self) }

    /// De-interleave `n` values of `size` bytes (byte b of value i is at b*n + i).
    mutating func interleaved(_ n: Int, _ size: Int) throws -> [UInt8] {
        try need(n * size)
        var out = [UInt8](repeating: 0, count: n * size)
        for b in 0..<size { for i in 0..<n { out[i * size + b] = buf[pos + b * n + i] } }
        pos += n * size
        return out
    }
    /// Big-endian u32s after de-interleaving.
    mutating func u32Array(_ n: Int) throws -> [UInt32] {
        let d = try interleaved(n, 4)
        return (0..<n).map { i in UInt32(d[i * 4]) << 24 | UInt32(d[i * 4 + 1]) << 16 | UInt32(d[i * 4 + 2]) << 8 | UInt32(d[i * 4 + 3]) }
    }
    /// Zig-zag decoded i32s.
    mutating func i32Array(_ n: Int) throws -> [Int32] {
        try u32Array(n).map { v in Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1))) }
    }
    /// Roblox float encoding: sign bit rotated to the lowest bit.
    mutating func f32Array(_ n: Int) throws -> [Float] {
        try u32Array(n).map { v in Float(bitPattern: (v >> 1) | (v << 31)) }
    }
    /// Delta-encoded referent ids.
    mutating func refArray(_ n: Int) throws -> [Int32] {
        var a = try i32Array(n)
        if n > 1 { for i in 1..<n { a[i] = a[i] &+ a[i - 1] } }
        return a
    }
    mutating func i64Array(_ n: Int) throws -> [Int64] {
        let d = try interleaved(n, 8)
        return (0..<n).map { i in
            var v: UInt64 = 0
            for b in 0..<8 { v = v << 8 | UInt64(d[i * 8 + b]) }
            return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
        }
    }
}

/// Little-endian writer, inverse of ByteReader (port of format/ByteWriter.kt).
struct ByteWriter {
    var out: [UInt8] = []

    mutating func u8(_ v: Int) { out.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v); u8(v >> 8) }
    mutating func i32(_ v: Int32) { let u = UInt32(bitPattern: v); for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: u >> UInt32(s))) } }
    mutating func i32(_ v: Int) { i32(Int32(truncatingIfNeeded: v)) }
    mutating func f32(_ v: Float) { i32(Int32(bitPattern: v.bitPattern)) }
    mutating func i64(_ v: Int64) { let u = UInt64(bitPattern: v); i32(Int32(bitPattern: UInt32(truncatingIfNeeded: u))); i32(Int32(bitPattern: UInt32(truncatingIfNeeded: u >> 32))) }
    mutating func f64(_ v: Double) { i64(Int64(bitPattern: v.bitPattern)) }
    mutating func bytes(_ b: [UInt8]) { out.append(contentsOf: b) }
    mutating func string(_ s: String) { let b = Array(s.utf8); i32(b.count); bytes(b) }
    mutating func string(_ b: [UInt8]) { i32(b.count); bytes(b) }
    mutating func string(_ d: Data) { i32(d.count); out.append(contentsOf: d) }

    mutating func interleaved(_ data: [UInt8], _ n: Int, _ size: Int) {
        for b in 0..<size { for i in 0..<n { out.append(data[i * size + b]) } }
    }
    mutating func u32Array(_ v: [UInt32]) {
        var d: [UInt8] = []; d.reserveCapacity(v.count * 4)
        for x in v { d += [UInt8(x >> 24 & 255), UInt8(x >> 16 & 255), UInt8(x >> 8 & 255), UInt8(x & 255)] }
        interleaved(d, v.count, 4)
    }
    mutating func i32Array(_ v: [Int32]) {
        u32Array(v.map { x in UInt32(bitPattern: (x << 1) ^ (x >> 31)) })
    }
    mutating func f32Array(_ v: [Float]) {
        u32Array(v.map { f in let b = f.bitPattern; return (b << 1) | (b >> 31) })
    }
    mutating func refArray(_ v: [Int32]) {
        var d = v
        if v.count > 1 { for i in stride(from: v.count - 1, through: 1, by: -1) { d[i] = v[i] &- v[i - 1] } }
        i32Array(d)
    }
    mutating func i64Array(_ v: [Int64]) {
        var d: [UInt8] = []
        for x in v {
            let z = UInt64(bitPattern: (x << 1) ^ (x >> 63))
            for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8(truncatingIfNeeded: z >> UInt64(s))) }
        }
        interleaved(d, v.count, 8)
    }
}

enum ChunkCodec {
    /// LZ4 block decompression (port of format/Lz4.kt).
    static func lz4(_ src: [UInt8], _ off: Int, _ len: Int, _ dstLen: Int) throws -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: dstLen)
        var s = off, d = 0
        let end = off + len
        func bad() -> RbxFormatError { RbxFormatError("Corrupt LZ4 data") }
        while s < end {
            let token = Int(src[s]); s += 1
            var lit = token >> 4
            if lit == 15 {
                while true { guard s < end else { throw bad() }; let b = Int(src[s]); s += 1; lit += b; if b != 255 { break } }
            }
            guard s + lit <= end, d + lit <= dstLen else { throw bad() }
            for k in 0..<lit { dst[d + k] = src[s + k] }
            s += lit; d += lit
            if s >= end { break }
            guard s + 2 <= end else { throw bad() }
            let offset = Int(src[s]) | Int(src[s + 1]) << 8; s += 2
            var ml = token & 15
            if ml == 15 {
                while true { guard s < end else { throw bad() }; let b = Int(src[s]); s += 1; ml += b; if b != 255 { break } }
            }
            ml += 4
            var m = d - offset
            guard m >= 0, offset > 0, d + ml <= dstLen else { throw bad() }
            for _ in 0..<ml { dst[d] = dst[m]; d += 1; m += 1 }
        }
        return dst
    }

    static func zstd(_ src: [UInt8], _ off: Int, _ len: Int, _ dstLen: Int) throws -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: dstLen)
        let r = src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                ZSTD_decompress(dp.baseAddress, dstLen, sp.baseAddress! + off, len)
            }
        }
        if ZSTD_isError(r) != 0 {
            throw RbxFormatError("Could not decompress ZSTD chunk: " + String(cString: ZSTD_getErrorName(r)))
        }
        return dst
    }
}
