import Foundation

/// BLAKE2b (RFC 7693), keyed, for satmux's keystream. CryptoKit has no BLAKE2b, and satmux's frames need it
/// byte for byte. Checked against RFC 7693's test vector and Python's `hashlib.blake2b` (BLAKE2bTests).
struct BLAKE2b {
    private static let iv: [UInt64] = [
        0x6A09_E667_F3BC_C908, 0xBB67_AE85_84CA_A73B, 0x3C6E_F372_FE94_F82B, 0xA54F_F53A_5F1D_36F1,
        0x510E_527F_ADE6_82D1, 0x9B05_688C_2B3E_6C1F, 0x1F83_D9AB_FB41_BD6B, 0x5BE0_CD19_137E_2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    /// The digest of `message` under `key` (at most 64 bytes), `digestSize` bytes long (1...64).
    static func hash(_ message: some Collection<UInt8>, key: some Collection<UInt8> = [UInt8](), digestSize: Int = 64)
        -> [UInt8] {
        precondition((1...64).contains(digestSize) && key.count <= 64)
        var h = iv
        h[0] ^= 0x0101_0000 ^ (UInt64(key.count) << 8) ^ UInt64(digestSize)

        var input = [UInt8]()
        if !key.isEmpty {
            input.append(contentsOf: key)
            input.append(contentsOf: repeatElement(0, count: 128 - key.count))
        }
        input.append(contentsOf: message)

        var offset = 0
        var counter: UInt64 = 0
        // Every block but the last is compressed as it comes; the last (even when full, or empty) is marked final.
        while input.count - offset > 128 {
            counter += 128
            compress(&h, input, offset, counter, last: false)
            offset += 128
        }
        let rest = input.count - offset
        var block = [UInt8](input[offset...])
        block.append(contentsOf: repeatElement(0, count: 128 - rest))
        counter += UInt64(rest)
        compress(&h, block, 0, counter, last: true)

        var out = [UInt8]()
        out.reserveCapacity(64)
        for word in h {
            for byte in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: word >> (8 * UInt64(byte))))
            }
        }
        return Array(out.prefix(digestSize))
    }

    private static func compress(_ h: inout [UInt64], _ bytes: [UInt8], _ offset: Int, _ counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for byte in 0..<8 {
                word |= UInt64(bytes[offset + i * 8 + byte]) << (8 * UInt64(byte))
            }
            m[i] = word
        }
        var v = h + iv
        v[12] ^= counter // The counter's high word stays 0: no message here comes near 2^64 bytes.
        if last {
            v[14] = ~v[14]
        }

        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }

        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }
}

private extension UInt64 {
    func rotatedRight(_ n: UInt64) -> UInt64 {
        (self >> n) | (self << (64 - n))
    }
}
