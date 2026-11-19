import CryptoKit
@testable import DurableNetworking
import Foundation
import Testing

/// The Swift port against what satmux.py itself makes (SatmuxVectors, from Tools/satmux/vectors.py).
struct SatmuxWireTests {
    private let psk = SymmetricKey(data: hex(SatmuxVectors.psk))
    private let nonce = hex(SatmuxVectors.nonce)
    private let session = hex(SatmuxVectors.session)

    @Test func blake2bMatchesRFC7693() {
        // RFC 7693 Appendix A: BLAKE2b-512("abc").
        #expect(BLAKE2b.hash(Array("abc".utf8)).hexString == """
        ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf\
        1925ab92386edd4009923
        """)
    }

    @Test(arguments: [0, 1, 64, 127, 128, 129, 255, 256, 1_000])
    func keyedBLAKE2bMatchesPython(length: Int) {
        let message = (0..<length).map { UInt8($0 % 251) }
        #expect(BLAKE2b.hash(message, key: [UInt8](hex(SatmuxVectors.blakeKey))).hexString
            == SatmuxVectors.keyedDigests[length])
    }

    @Test func keystreamMatchesSatmux() {
        let key = SymmetricKey(data: hex(SatmuxVectors.blakeKey))
        #expect(SatmuxWire.xor(Data(count: 200), key: key, seq: 7).hexString == SatmuxVectors.keystream)
    }

    @Test func handshakeAndKeysMatchSatmux() {
        #expect(SatmuxWire.hello(psk: psk, nonce: nonce, session: session) == hex(SatmuxVectors.hello))
        #expect(SatmuxWire.isRelayProof(hex(SatmuxVectors.proof), psk: psk, nonce: nonce, session: session))
        #expect(!SatmuxWire.isRelayProof(Data(count: 32), psk: psk, nonce: nonce, session: session))
        let keys = SatmuxWire.keys(psk: psk, nonce: nonce, session: session)
        #expect(keys.send.data == hex(SatmuxVectors.clientToRelay))
        #expect(keys.receive.data == hex(SatmuxVectors.relayToClient))
    }

    @Test func readsSatmuxsFetchFrame() throws {
        let frame = hex(SatmuxVectors.fetchFrame)
        let header = SatmuxWire.header(frame.prefix(7))
        #expect(header.type == SatmuxWire.FrameType.fetch.rawValue)
        #expect(header.stream == 3)
        #expect(header.length == frame.count - 7)
        let relayKey = SymmetricKey(data: hex(SatmuxVectors.clientToRelay))
        #expect(try SatmuxWire.open(frame.dropFirst(7), key: relayKey) == hex(SatmuxVectors.request))
    }

    @Test func writesTheFetchSatmuxReads() throws {
        var request = URLRequest(url: URL(string: "https://example.test/v1/items?x=1")!)
        request.setValue("Bearer t0ken", forHTTPHeaderField: "Authorization")
        #expect(try SatmuxWire.fetchRequest(request) == hex(SatmuxVectors.request))

        // Sealed here, opened as the relay opens it. The bytes differ from Python's (zlib is free to choose its
        // encoding); the relay's `zlib.decompress` reads either, as SatmuxRelayTests shows end to end.
        let keys = SatmuxWire.keys(psk: psk, nonce: nonce, session: session)
        let frame = SatmuxWire.encode(.init(
            type: SatmuxWire.FrameType.fetch.rawValue, stream: 3,
            payload: try SatmuxWire.seal(hex(SatmuxVectors.request), key: keys.send, seq: 1)
        ))
        #expect(frame.prefix(5) == hex(SatmuxVectors.fetchFrame).prefix(5))
        #expect(try SatmuxWire.open(frame.dropFirst(7), key: keys.send) == hex(SatmuxVectors.request))
    }

    @Test func readsTheRelaysAnswer() throws {
        let keys = SatmuxWire.keys(psk: psk, nonce: nonce, session: session)
        var answer = Data()
        for frame in SatmuxVectors.answerFrames.map(hex) {
            let header = SatmuxWire.header(frame.prefix(7))
            #expect(header.stream == 3)
            if header.type == SatmuxWire.FrameType.encrypted.rawValue {
                answer.append(try SatmuxWire.open(frame.dropFirst(7), key: keys.receive))
            } else {
                #expect(header.type == SatmuxWire.FrameType.fin.rawValue)
            }
        }
        let url = URL(string: "https://example.test/v1/items?x=1")!
        let (body, response) = try SatmuxWire.response(answer, url: url)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(response.value(forHTTPHeaderField: "Set-Cookie") == "a=1, b=2")
        #expect(SatmuxTransport.isRelayed(response))
        #expect(body == hex(SatmuxVectors.responseBody))
    }

    @Test func zlibRoundTripsAndChecksItsTrailer() throws {
        for size in [0, 1, 100, 70_000] {
            let data = Data((0..<size).map { UInt8($0 % 7) })
            #expect(try Zlib.decompress(Zlib.compress(data)) == data)
        }
        var corrupt = try Zlib.compress(Data("hello".utf8))
        corrupt[corrupt.count - 1] ^= 1
        #expect(throws: SatmuxError.badFrame) { try Zlib.decompress(corrupt) }
    }

    @Test func relayableRequestsAreReads() {
        var read = URLRequest(url: URL(string: "https://example.test/a")!)
        #expect(SatmuxTransport.isRelayable(read))
        read.httpMethod = "POST"
        read.httpBody = Data("{}".utf8)
        #expect(!SatmuxTransport.isRelayable(read))
        #expect(!SatmuxTransport.isRelayable(URLRequest(url: URL(string: "ftp://example.test/a")!)))
    }

    @Test func relayKeyIsParsedAtTheBoundary() throws {
        let relay = try SatmuxRelay(host: "relay.test", port: 8_444, keyHex: SatmuxVectors.psk)
        #expect(relay.key.data == hex(SatmuxVectors.psk))
        #expect(throws: SatmuxError.badRelay) { try SatmuxRelay(host: "relay.test", port: 8_444, keyHex: "abc") }
        #expect(throws: SatmuxError.badRelay) {
            try SatmuxRelay(host: "relay.test", port: 0, keyHex: SatmuxVectors.psk)
        }
        #expect(throws: SatmuxError.badRelay) {
            try SatmuxRelay(host: "relay.test", port: 8_444, keyHex: String(repeating: "zz", count: 32))
        }
    }
}

func hex(_ string: String) -> Data {
    var out = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        out.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return out
}

extension Collection<UInt8> {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
