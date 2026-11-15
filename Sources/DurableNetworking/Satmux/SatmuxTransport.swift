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
/// The relay sees each request it makes, credentials included: engage only a relay you run.
///
/// ```swift
/// let boost = SatmuxTransport(direct: URLSessionTransport(isInForeground: inForeground))
/// let transport = RetryingTransport(inner: boost, isInForeground: inForeground)
/// await boost.engage(try SatmuxRelay(host: config.host, port: config.port, keyHex: config.key)) // the setting on
/// await boost.disengage() // the setting off
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

    /// Opens carriers to `relay` and sends through it from now on. Engaging the relay already engaged does nothing.
    public func engage(_ relay: SatmuxRelay) async {
        await engagement.engage(relay, carriers: carriers)
    }

    /// Closes the carriers; requests go `direct` again.
    public func disengage() async {
        await engagement.engage(nil, carriers: carriers)
    }

    /// The relay engaged now, if any.
    public var relay: SatmuxRelay? {
        get async { await engagement.pool?.relay }
    }

    /// Carriers open now.
    public var openCarriers: Int {
        get async { await engagement.pool?.openCount ?? 0 }
    }

    /// The round trip to the relay the carriers last measured: the link's own latency, for deciding whether
    /// engaging pays.
    public var roundTrip: Duration? {
        get async { await engagement.pool?.roundTrip }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard relays(request), let url = request.url, let pool = await engagement.pool,
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

private actor Engagement {
    private(set) var pool: SatmuxPool?

    func engage(_ relay: SatmuxRelay?, carriers: Int) async {
        guard pool?.relay != relay else {
            return
        }
        await pool?.stop()
        pool = nil
        if let relay {
            let next = SatmuxPool(relay: relay, size: carriers)
            pool = next
            await next.start()
        }
    }
}
