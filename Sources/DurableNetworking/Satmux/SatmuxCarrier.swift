import CryptoKit
import Foundation
import Network
import Synchronization

public enum SatmuxError: Error, Equatable {
    /// The relay key isn't 64 hex characters (32 bytes), or the port isn't one.
    case badRelay
    /// The relay didn't prove it holds the key: a wrong key, or not a satmux relay.
    case relayRejected
    /// A frame or its payload didn't decode.
    case badFrame
    /// The relay's answer wasn't an HTTP response.
    case badResponse
    /// The request can't travel as a ground fetch (a body, a scheme other than http(s), a header with a newline).
    case notRelayable
}

/// One warm TCP connection to the relay, many ground fetches over it at once.
final class SatmuxCarrier: Sendable {
    let slot: Int
    private let connection: NWConnection
    private let keys: SatmuxWire.Keys
    private let state: Mutex<State>

    fileprivate struct State {
        var seq: UInt64 = 0
        var nextStream: UInt32 = 1
        var fetches: [UInt32: Fetch] = [:]
        var isOpen = true
        var closedWaiters: [CheckedContinuation<Void, Never>] = []
        /// Bytes sent and received, decaying to 35% each second: how busy the carrier is now.
        var load = 0.0
        var loadAt = ContinuousClock.now
        /// Fetches sent that have no answer yet.
        var waiting = 0
        var roundTrip: Duration?
    }

    fileprivate struct Fetch {
        var received = Data()
        var answered = false
        let done: CheckedContinuation<Data, any Error>
    }

    private init(slot: Int, connection: NWConnection, keys: SatmuxWire.Keys) {
        self.slot = slot
        self.connection = connection
        self.keys = keys
        state = Mutex(State())
    }

    /// Connects, shakes hands and starts reading. Throws when the relay can't be reached or doesn't hold the key.
    static func open(to relay: SatmuxRelay, session: Data, slot: Int) async throws -> SatmuxCarrier {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 12
        let connection = NWConnection(
            host: NWEndpoint.Host(relay.host), port: NWEndpoint.Port(rawValue: relay.port)!,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        do {
            try await ready(connection)
            let nonce = try await receive(connection, exactly: SatmuxWire.nonceLength)
            try await send(connection, SatmuxWire.hello(psk: relay.key, nonce: nonce, session: session))
            let proof = try await receive(connection, exactly: 32)
            guard SatmuxWire.isRelayProof(proof, psk: relay.key, nonce: nonce, session: session) else {
                throw SatmuxError.relayRejected
            }
            let carrier = SatmuxCarrier(
                slot: slot, connection: connection,
                keys: SatmuxWire.keys(psk: relay.key, nonce: nonce, session: session)
            )
            carrier.watch()
            Task { await carrier.read() }
            return carrier
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: Fetching

    /// Sends `request` (`SatmuxWire.fetchRequest`) and returns the relay's whole answer.
    func fetch(_ request: Data) async throws -> Data {
        let (stream, seq) = try state.withLock { state in
            guard state.isOpen else {
                throw URLError(.networkConnectionLost)
            }
            defer {
                state.nextStream &+= 1
                state.seq &+= 1
            }
            return (state.nextStream, state.seq + 1)
        }
        let sealed = try SatmuxWire.seal(request, key: keys.send, seq: seq)
        guard sealed.count <= Int(UInt16.max) else {
            throw SatmuxError.notRelayable
        }
        let frame = SatmuxWire.encode(.init(type: SatmuxWire.FrameType.fetch.rawValue, stream: stream, payload: sealed))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, any Error>) in
                let isOpen = state.withLock { state in
                    guard state.isOpen else {
                        return false
                    }
                    state.fetches[stream] = Fetch(done: done)
                    state.waiting += 1
                    state.record(frame.count)
                    return true
                }
                guard isOpen else {
                    done.resume(throwing: URLError(.networkConnectionLost))
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.close()
                    }
                })
            }
        } onCancel: {
            finish(stream, with: .failure(CancellationError()))
        }
    }

    // MARK: Health

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    /// How busy the carrier is, for choosing one: lower is better. satmux's own order: a busy band (idle, light,
    /// heavy), then fetches waiting, then bytes.
    var busyness: (band: Int, waiting: Int, kilobytes: Int) {
        state.withLock { state in
            let load = state.currentLoad
            return (load < 4_096 ? 0 : load < 65_536 ? 1 : 2, state.waiting, Int(load / 4_096))
        }
    }

    var roundTrip: Duration? {
        state.withLock { $0.roundTrip }
    }

    /// Sends satmux's keep-alive ping; the relay's pong measures the round trip.
    func ping() {
        let sent = Date().timeIntervalSince1970.bitPattern.bigEndian
        let payload = withUnsafeBytes(of: sent) { Data($0) }
        let frame = SatmuxWire.encode(.init(type: SatmuxWire.FrameType.ping.rawValue, stream: 0, payload: payload))
        state.withLock { $0.record(frame.count) }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }

    func close() {
        let (fetches, waiters) = state.withLock { state -> ([Fetch], [CheckedContinuation<Void, Never>]) in
            guard state.isOpen else {
                return ([], [])
            }
            state.isOpen = false
            defer {
                state.fetches = [:]
                state.closedWaiters = []
            }
            return (Array(state.fetches.values), state.closedWaiters)
        }
        connection.cancel()
        fetches.forEach { $0.done.resume(throwing: URLError(.networkConnectionLost)) }
        waiters.forEach { $0.resume() }
    }

    /// Returns once the carrier has closed, for whatever reason.
    func closed() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state in
                if state.isOpen {
                    state.closedWaiters.append(waiter)
                }
                return state.isOpen
            }
            if !isOpen {
                waiter.resume()
            }
        }
    }

    // MARK: Reading

    private func watch() {
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
    }

    private func read() async {
        do {
            while isOpen {
                let header = SatmuxWire.header(try await Self.receive(connection, exactly: SatmuxWire.headerLength))
                let payload = header.length > 0 ? try await Self.receive(connection, exactly: header.length) : Data()
                try handle(type: header.type, stream: header.stream, payload: payload)
            }
        } catch {
            close()
        }
    }

    private func handle(type: UInt8, stream: UInt32, payload: Data) throws {
        state.withLock { $0.record(SatmuxWire.headerLength + payload.count) }
        switch SatmuxWire.FrameType(rawValue: type) {
        case .pong:
            guard payload.count == 8 else {
                return
            }
            let sent = Double(bitPattern: payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            let seconds = Date().timeIntervalSince1970 - sent
            if seconds >= 0, seconds < 60 {
                state.withLock { $0.roundTrip = .milliseconds(Int(seconds * 1_000)) }
            }
        case .encrypted:
            append(try SatmuxWire.open(payload, key: keys.receive), to: stream)
        case .raw:
            append(payload, to: stream)
        case .zlib:
            append(try Zlib.decompress(payload), to: stream)
        case .fin:
            let received = state.withLock { $0.fetches[stream]?.received } ?? Data()
            finish(stream, with: .success(received))
        case .reset:
            finish(stream, with: .failure(URLError(.networkConnectionLost)))
        default:
            break // Frames for satmux's tunnel mode, which this client doesn't open.
        }
    }

    private func append(_ bytes: Data, to stream: UInt32) {
        state.withLock { state in
            guard var fetch = state.fetches[stream] else {
                return
            }
            if !fetch.answered {
                fetch.answered = true
                state.waiting = max(0, state.waiting - 1)
            }
            fetch.received.append(bytes)
            state.fetches[stream] = fetch
        }
    }

    private func finish(_ stream: UInt32, with result: Result<Data, any Error>) {
        let fetch = state.withLock { state -> Fetch? in
            guard let fetch = state.fetches.removeValue(forKey: stream) else {
                return nil
            }
            if !fetch.answered {
                state.waiting = max(0, state.waiting - 1)
            }
            return fetch
        }
        fetch?.done.resume(with: result)
    }

    // MARK: NWConnection, async

    private static func ready(_ connection: NWConnection) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            let resume: @Sendable (Result<Void, any Error>) -> Void = { result in
                if once.first() {
                    done.resume(with: result)
                }
            }
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    resume(.success(()))
                case .failed(let error), .waiting(let error):
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(URLError(.cancelled)))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "durable-networking.satmux.carrier"))
        }
    }

    private static func receive(_ connection: NWConnection, exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    done.resume(throwing: error)
                } else if let data, data.count == count {
                    done.resume(returning: data)
                } else {
                    done.resume(throwing: isComplete ? URLError(.networkConnectionLost) : SatmuxError.badFrame)
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    done.resume(throwing: error)
                } else {
                    done.resume()
                }
            })
        }
    }
}

private extension SatmuxCarrier.State {
    var currentLoad: Double {
        load * pow(0.35, (ContinuousClock.now - loadAt).seconds)
    }

    mutating func record(_ bytes: Int) {
        load = currentLoad + Double(bytes)
        loadAt = .now
    }
}

/// True for the first caller only.
private final class Once: Sendable {
    private let called = Mutex(false)

    func first() -> Bool {
        called.withLock { called in
            defer { called = true }
            return !called
        }
    }
}
