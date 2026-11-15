import CryptoKit
import Foundation

/// A satmux ground relay: where it is and the key it shares with its clients. The host gets these from its own
/// server, never from its binary.
public struct SatmuxRelay: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    var key: SymmetricKey

    /// `keyHex` is the relay's pre-shared key as satmux takes it (`SATMUX_PSK`): 64 hex characters.
    public init(host: String, port: Int, keyHex: String) throws {
        guard !host.isEmpty, (1...Int(UInt16.max)).contains(port), keyHex.count == 64,
              let bytes = Self.bytes(hex: keyHex)
        else {
            throw SatmuxError.badRelay
        }
        self.host = host
        self.port = UInt16(port)
        key = SymmetricKey(data: bytes)
    }

    public static func == (lhs: SatmuxRelay, rhs: SatmuxRelay) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port && lhs.key.data == rhs.key.data
    }

    private static func bytes(hex: String) -> Data? {
        var out = Data()
        var high: UInt8?
        for character in hex {
            guard let nibble = character.hexDigitValue.map(UInt8.init) else {
                return nil
            }
            if let h = high {
                out.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return out
    }
}

/// The warm carriers to one relay: each slot connects, shakes hands and stays open, and reconnects after a drop
/// (1 s, growing by half to 5 s); every 12 s each is pinged, which keeps cabin middleboxes from dropping it and
/// measures the round trip.
actor SatmuxPool {
    let relay: SatmuxRelay
    private let size: Int
    private let session: Data
    private var carriers: [Int: SatmuxCarrier] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var rotation = 0

    init(relay: SatmuxRelay, size: Int) {
        self.relay = relay
        self.size = size
        session = Data((0..<SatmuxWire.sessionLength).map { _ in UInt8.random(in: .min ... .max) })
    }

    func start() {
        guard tasks.isEmpty else {
            return
        }
        tasks = (1...size).map { slot in Task { await self.keep(slot) } }
        tasks.append(Task { await self.pingEvery(.seconds(12)) })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        carriers.values.forEach { $0.close() }
        carriers = [:]
    }

    /// The least busy open carrier, waiting up to `wait` for one to open.
    func carrier(within wait: Duration) async -> SatmuxCarrier? {
        let deadline = ContinuousClock.now + wait
        while true {
            if let best = leastBusy() {
                return best
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    var openCount: Int {
        carriers.values.filter(\.isOpen).count
    }

    /// The median round trip the carriers measured, once one has.
    var roundTrip: Duration? {
        let trips = carriers.values.compactMap(\.roundTrip).sorted()
        return trips.isEmpty ? nil : trips[trips.count / 2]
    }

    private func leastBusy() -> SatmuxCarrier? {
        let open = carriers.values.filter(\.isOpen)
        rotation = (rotation + 1) % 97
        let rotation = rotation
        // Ties go round-robin, as satmux's own client does, so idle carriers share the work.
        return open.min { a, b in
            let (x, y) = (a.busyness, b.busyness)
            if x != y {
                return (x.band, x.waiting, x.kilobytes) < (y.band, y.waiting, y.kilobytes)
            }
            return (a.slot + rotation) % 97 < (b.slot + rotation) % 97
        }
    }

    private func keep(_ slot: Int) async {
        var backoff = 1.0
        while !Task.isCancelled {
            if let carrier = try? await SatmuxCarrier.open(to: relay, session: session, slot: slot) {
                guard !Task.isCancelled else {
                    carrier.close()
                    return
                }
                carriers[slot] = carrier
                carrier.ping()
                backoff = 1
                await carrier.closed()
                carriers[slot] = nil
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 1.5, 5)
        }
    }

    private func pingEvery(_ interval: Duration) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            carriers.values.filter(\.isOpen).forEach { $0.ping() }
        }
    }
}
