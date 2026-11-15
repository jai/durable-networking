import Foundation

/// zlib streams (RFC 1950) as Python's `zlib` writes and reads them. Apple's `.zlib` is raw deflate (RFC 1951), so
/// this adds and checks the two-byte header and the Adler-32 trailer around it.
enum Zlib {
    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x78, 0x9C]) // Deflate, 32 KiB window, default level: what Python writes at level 6.
        out.append(deflated)
        withUnsafeBytes(of: adler32(data).bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0,
              bytes[1] & 0x20 == 0 // No preset dictionary.
        else {
            throw SatmuxError.badFrame
        }
        let body = Data(bytes[2..<(bytes.count - 4)])
        let inflated = body.isEmpty ? Data() : try (body as NSData).decompressed(using: .zlib) as Data
        let trailer = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard adler32(inflated) == trailer else {
            throw SatmuxError.badFrame
        }
        return inflated
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { raw in
            // 5,552 bytes is the most that can be summed before the 32-bit sums must be reduced (zlib's NMAX).
            var start = 0
            while start < raw.count {
                let end = min(start + 5_552, raw.count)
                for i in start..<end {
                    a &+= UInt32(raw[i])
                    b &+= a
                }
                a %= 65_521
                b %= 65_521
                start = end
            }
        }
        return b << 16 | a
    }
}
