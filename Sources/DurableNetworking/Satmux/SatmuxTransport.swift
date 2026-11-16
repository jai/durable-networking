import Foundation

/// Sends requests through a satmux ground relay (https://github.com/Th0rgal/satmux) when the host engages one, and
/// through `direct` otherwise. For links with a very long round trip, such as airplane Wi-Fi over a geostationary
/// satellite (about 600 ms): a request made directly pays several round trips (DNS, TCP, TLS, then the request) and
/// TCP's slow start; through the relay it is one round trip over a connection already open, and the relay does the
/// rest on the ground and sends the answer back compressed.
///
/// Engaged, it holds a pool of warm carriers to the relay (12 by default). A request goes through the relay when
/// `relays` says so (by default: an http(s) read, `GET` or `HEAD`, since satmux's relay sends no body and a read
/// is safe to make again from here); anything else, a request
/// made before a carrier opens (`warmWait`), and a request the relay itself couldn't make (it answers 502 with no
/// satmux marker) go `direct`. A carrier that drops mid-request throws `URLError(.networkConnectionLost)`, which
/// `RetryingTransport` repeats when that is safe.
///
/// Engaged with `.automatic`, the carriers stay open but reads go through them only while the link is slow
/// (`SatmuxMode`): a host can leave it on, and it carries reads on a plane and steps aside on the ground.
///
/// The relay sees each request it makes, credentials included: engage only a relay you run.
///
/// ```swift
/// let boost = SatmuxTransport(direct: URLSessionTransport(isInForeground: inForeground))
/// let transport = RetryingTransport(inner: boost, isInForeground: inForeground)
/// await boost.engage(try SatmuxRelay(host: config.host, port: config.port, keyHex: config.key)) // the setting on
/// await boost.disengage() // the setting off
/// await boost.engage(relay, mode: .automatic) // or: only while the link is slow
/// ```
public final class SatmuxTransport: HTTPTransport {
    private let direct: any HTTPTransport
    private let carriers: Int
    private let warmWait: Duration
    private let relays: @Sendable (URLRequest) -> Bool
    private let engagement: Engagement

    public convenience init(
        direct: any HTTPTransport, carriers: Int = 12, warmWait: Duration = .seconds(3),
        relays: @escaping @Sendable (URLRequest) -> Bool = SatmuxTransport.isRelayable
    ) {
        self.init(direct: direct, carriers: carriers, warmWait: warmWait, relays: relays, engagement: Engagement())
    }

    private init(
        direct: any HTTPTransport, carriers: Int, warmWait: Duration,
        relays: @escaping @Sendable (URLRequest) -> Bool, engagement: Engagement
    ) {
        self.direct = direct
        self.carriers = max(1, carriers)
        self.warmWait = warmWait
        self.relays = relays
        self.engagement = engagement
    }

    /// A transport over the same carriers, engaged and disengaged with this one, that falls back to another
    /// `direct`: for a host with two sessions (one that waits for a network, one that doesn't) and one relay.
    public func sharingCarriers(direct: any HTTPTransport) -> SatmuxTransport {
        SatmuxTransport(direct: direct, carriers: carriers, warmWait: warmWait, relays: relays, engagement: engagement)
    }

    /// Opens carriers to `relay` and sends through it from now on: always, or only while the link is slow (`mode`).
    /// Engaging the relay already engaged keeps its carriers and takes the new `mode`.
    public func engage(_ relay: SatmuxRelay, mode: SatmuxMode = .always) async {
        await engagement.engage(relay, carriers: carriers, mode: mode)
    }

    /// Closes the carriers; requests go `direct` again.
    public func disengage() async {
        await engagement.engage(nil, carriers: carriers, mode: .always)
    }

    /// Whether reads go through the relay now: engaged, and with `.automatic`, the link is slow. A read still goes
    /// `direct` while no carrier is open.
    public var isRelaying: Bool {
        get async { await engagement.relayingPool() != nil }
    }

    /// The relay engaged now, if any.
    public var relay: SatmuxRelay? {
        get async { await engagement.currentPool?.relay }
    }

    /// Carriers open now.
    public var openCarriers: Int {
        get async { await engagement.currentPool?.openCount ?? 0 }
    }

    /// The round trip to the relay the carriers last measured: the link's own latency, for deciding whether
    /// engaging pays.
    public var roundTrip: Duration? {
        get async { await engagement.currentPool?.roundTrip }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard relays(request), let url = request.url, let pool = await engagement.relayingPool(),
              let fetch = try? SatmuxWire.fetchRequest(request),
              let carrier = await pool.carrier(within: warmWait)
        else {
            return try await direct.send(request)
        }
        let answer: Data
        do {
            answer = try await withDeadline(.seconds(request.timeoutInterval)) { try await carrier.fetch(fetch) }
        } catch is DeadlineExceeded {
            throw URLError(.timedOut)
        } catch SatmuxError.notRelayable {
            return try await direct.send(request)
        }
        let (data, response) = try SatmuxWire.response(answer, url: url)
        guard response.value(forHTTPHeaderField: SatmuxWire.fetchedMarker) != nil else {
            // The relay couldn't reach the server (a host only this device can reach, say): try it from here.
            return try await direct.send(request)
        }
        return (data, response)
    }

    /// Whether `request` is a read the relay can make: http(s) `GET` or `HEAD` with no body. A read, because when the
    /// relay fails it is made again directly.
    public static func isRelayable(_ request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return (request.httpBody?.isEmpty ?? true) && request.httpBodyStream == nil
            && ["GET", "HEAD"].contains(request.httpMethod ?? "GET")
    }

    /// Whether `response` came through the relay.
    public static func isRelayed(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: SatmuxWire.fetchedMarker) != nil
    }
}

/// When an engaged relay carries reads.
public enum SatmuxMode: Sendable, Equatable {
    /// Every read it can make, once a carrier is open.
    case always
    /// Only while the link is slow: from when the round trip the carriers measure to the relay rises above `above`
    /// until it falls below `below`. The gap keeps it from flapping. The carriers stay open either way, so they go on
    /// measuring (a ping every 12 s) and are warm when the link slows.
    case whenRoundTrip(above: Duration, below: Duration)

    /// On above 300 ms, off below 200 ms. A ground link is well under 100 ms to a nearby relay; cabin Wi-Fi over a
    /// geostationary satellite is about 600 ms, and over a low-orbit one under 100 ms, where the relay gains little.
    public static let automatic = SatmuxMode.whenRoundTrip(above: .milliseconds(300), below: .milliseconds(200))

    /// Whether reads go through the relay, given whether they did and the round trip measured now (none yet: no
    /// change).
    func relays(wasRelaying: Bool, roundTrip: Duration?) -> Bool {
        switch self {
        case .always:
            return true
        case let .whenRoundTrip(above, below):
            guard let roundTrip else {
                return wasRelaying
            }
            return wasRelaying ? roundTrip >= below : roundTrip > above
        }
    }
}

private actor Engagement {
    private var pool: SatmuxPool?
    private var mode = SatmuxMode.always
    private var relaying = false

    func engage(_ relay: SatmuxRelay?, carriers: Int, mode: SatmuxMode) async {
        self.mode = mode
        guard pool?.relay != relay else {
            return
        }
        relaying = false
        await pool?.stop()
        pool = nil
        if let relay {
            let next = SatmuxPool(relay: relay, size: carriers)
            pool = next
            await next.start()
        }
    }

    /// The carriers reads go through now, if they go through any.
    func relayingPool() async -> SatmuxPool? {
        guard let pool else {
            return nil
        }
        if mode == .always {
            return pool
        }
        let roundTrip = await pool.roundTrip
        guard pool === self.pool else {
            return nil // Engaged elsewhere while measuring.
        }
        relaying = mode.relays(wasRelaying: relaying, roundTrip: roundTrip)
        return relaying ? pool : nil
    }

    var currentPool: SatmuxPool? {
        pool
    }
}
