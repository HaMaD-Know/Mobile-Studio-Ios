import Foundation

/// Strips a gzip wrapper if present (files downloaded from the web are sometimes gzipped).
enum Gzip {
    static func unwrap(_ b: Data) throws -> Data {
        guard b.count > 18, b[b.startIndex] == 0x1F, b[b.startIndex + 1] == 0x8B else { return b }
        let d = [UInt8](b)
        guard d[2] == 8 else { throw RbxFormatError("Unsupported gzip compression method") }
        let flags = d[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= d.count else { throw bad }; p += 2 + (Int(d[p]) | (Int(d[p + 1]) << 8)) }
        if flags & 8 != 0 { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }   // file name
        if flags & 16 != 0 { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }  // comment
        if flags & 2 != 0 { p += 2 }                                               // header crc
        guard p < d.count - 8 else { throw bad }
        let deflate = Data(d[p..<(d.count - 8)])
        // NSData's .zlib algorithm is raw DEFLATE (RFC 1951), which is what gzip wraps.
        guard let out = try? (deflate as NSData).decompressed(using: .zlib) as Data else {
            throw RbxFormatError("Could not decompress gzip data")
        }
        return out
    }
    private static var bad: RbxFormatError { RbxFormatError("Corrupt gzip header") }
}
