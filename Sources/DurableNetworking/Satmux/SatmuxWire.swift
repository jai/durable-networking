import CryptoKit
import Foundation

/// satmux's wire format (https://github.com/Th0rgal/satmux, `satmux.py`, MIT, at 2922ebb), the parts a client of its
/// 1-RTT ground fetch needs. Values only: the carrier sends and receives them.
///
/// A carrier opens with a handshake: the relay sends a 32-byte nonce; the client answers a 16-byte session id and
/// `HMAC-SHA256(psk, "ORB-MUX-V3" + nonce + session)`; the relay proves it holds the key with
/// `HMAC-SHA256(psk, "ORB-MUX-V3-OK" + nonce + session)`. Then frames both ways: type (1 byte), stream id (4), payload
/// length (2), big-endian, then the payload.
///
/// A ground fetch is one `fetch` frame (the request) and the relay's `encrypted` frames then `fin` (the whole HTTP/1.1
/// response). Their payloads are a sequence number (8 bytes) and zlib data XORed with a BLAKE2b keystream keyed per
/// carrier and direction. The keystream hides the content; it does not authenticate it, and the relay sees the
/// request in the clear: it makes it.
enum SatmuxWire {
    enum FrameType: UInt8, Sendable {
        case open = 1
        case raw = 4
        case zlib = 5
        case fin = 6
        case reset = 7
        case ping = 8
        case pong = 9
        case fetch = 10
        case encrypted = 11
    }

    struct Frame: Equatable, Sendable {
        var type: UInt8
        var stream: UInt32
        var payload: Data
    }

    static let headerLength = 7
    static let nonceLength = 32
    static let sessionLength = 16

    // MARK: Handshake and keys

    struct Keys: Equatable, Sendable {
        /// Client to relay.
        var send: SymmetricKey
        /// Relay to client.
        var receive: SymmetricKey

        static func == (lhs: Keys, rhs: Keys) -> Bool {
            lhs.send.data == rhs.send.data && lhs.receive.data == rhs.receive.data
        }
    }

    /// The client's half of the handshake: its session id and proof.
    static func hello(psk: SymmetricKey, nonce: Data, session: Data) -> Data {
        session + mac(psk, "ORB-MUX-V3", nonce, session)
    }

    /// Whether the relay's answer proves it holds the same key.
    static func isRelayProof(_ proof: Data, psk: SymmetricKey, nonce: Data, session: Data) -> Bool {
        let expected = "ORB-MUX-V3-OK".data(using: .utf8)! + nonce + session
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: expected, using: psk)
    }

    static func keys(psk: SymmetricKey, nonce: Data, session: Data) -> Keys {
        Keys(
            send: SymmetricKey(data: mac(psk, "ORB-V3-C2S", nonce, session)),
            receive: SymmetricKey(data: mac(psk, "ORB-V3-S2C", nonce, session))
        )
    }

    private static func mac(_ psk: SymmetricKey, _ label: String, _ nonce: Data, _ session: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + nonce + session, using: psk))
    }

    // MARK: Frames

    static func encode(_ frame: Frame) -> Data {
        precondition(frame.payload.count <= Int(UInt16.max), "satmux frames carry at most 65,535 bytes")
        var out = Data(capacity: headerLength + frame.payload.count)
        out.append(frame.type)
        withUnsafeBytes(of: frame.stream.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(frame.payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(frame.payload)
        return out
    }

    /// The type, stream and payload length from a 7-byte header.
    static func header(_ bytes: Data) -> (type: UInt8, stream: UInt32, length: Int) {
        let b = [UInt8](bytes)
        let stream = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        return (b[0], stream, Int(b[5]) << 8 | Int(b[6]))
    }

    // MARK: Sealed payloads

    /// `seq` (8 bytes, big-endian) then `zlib(data)` XORed with the keystream for `seq`.
    static func seal(_ data: Data, key: SymmetricKey, seq: UInt64) throws -> Data {
        var out = Data()
        withUnsafeBytes(of: seq.bigEndian) { out.append(contentsOf: $0) }
        out.append(xor(try Zlib.compress(data), key: key, seq: seq))
        return out
    }

    static func open(_ payload: Data, key: SymmetricKey) throws -> Data {
        guard payload.count >= 8 else {
            throw SatmuxError.badFrame
        }
        let seq = payload.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return try Zlib.decompress(xor(payload.dropFirst(8), key: key, seq: seq))
    }

    /// satmux's keystream: block `n` is `BLAKE2b-512(key: key, message: seq ‖ n)`, both 8 bytes big-endian.
    static func xor(_ data: Data, key: SymmetricKey, seq: UInt64) -> Data {
        let keyBytes = key.withUnsafeBytes { [UInt8]($0) }
        var out = [UInt8](data)
        var block: UInt64 = 0
        var at = 0
        while at < out.count {
            var message = [UInt8]()
            withUnsafeBytes(of: seq.bigEndian) { message.append(contentsOf: $0) }
            withUnsafeBytes(of: block.bigEndian) { message.append(contentsOf: $0) }
            let stream = BLAKE2b.hash(message, key: keyBytes)
            for byte in stream where at < out.count {
                out[at] ^= byte
                at += 1
            }
            block += 1
        }
        return Data(out)
    }

    // MARK: Ground fetch

    /// The request a `fetch` frame seals: method, URL, then each header as `Name: value`, one per line. satmux's
    /// relay sends no body, sets its own `Host`, `Connection`, `Accept`, `Accept-Encoding` and `User-Agent`, and
    /// follows redirects.
    static func fetchRequest(_ request: URLRequest) throws -> Data {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw SatmuxError.notRelayable
        }
        var lines = [request.httpMethod ?? "GET", url.absoluteString]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !(name + value).contains(where: \.isNewline) else {
                throw SatmuxError.notRelayable
            }
            lines.append("\(name): \(value)")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The marker satmux's relay adds to an answer it fetched. Its own failure (`502 Mux Fetch Error`) has none.
    static let fetchedMarker = "X-Orb-Sat-Mux"

    /// The HTTP/1.1 response the relay sent back: status line, headers, blank line, body.
    static func response(_ bytes: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        guard let end = bytes.firstRange(of: Data("\r\n\r\n".utf8)) else {
            throw SatmuxError.badResponse
        }
        let head = String(decoding: bytes[bytes.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else {
            throw SatmuxError.badResponse
        }
        var headers = [String: String]()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            throw SatmuxError.badResponse
        }
        return (Data(bytes[end.upperBound...]), http)
    }
}

extension SymmetricKey {
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
