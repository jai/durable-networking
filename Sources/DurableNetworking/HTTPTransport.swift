import Foundation
import Network

/// Sends one request. The only way a host or a kit reaches a server: kits take one from their host, and only this
/// package makes a `URLSession`. `RetryingTransport` over `URLSessionTransport` in an app; a scripted stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Equatable {
    case notHTTP
}

/// How a `URLSession` here waits.
public struct SessionPolicy: Sendable, Equatable {
    /// The longest silence a request allows between bytes.
    public var requestTimeout: TimeInterval
    /// A request made with no network waits for one, up to `resourceTimeout`, so an elevator delays it and doesn't
    /// fail it. Off for a background wake, which has a budget, and for anything with its own fallback.
    public var waitsForConnectivity: Bool
    public var resourceTimeout: TimeInterval?
    /// A SOCKS5 proxy every connection goes through: the demo's emulated satellite link (Demo/server/geo_link.py).
    /// The system skips it for loopback and local-network addresses.
    public var socksProxy: SOCKSProxy?

    public init(
        requestTimeout: TimeInterval, waitsForConnectivity: Bool, resourceTimeout: TimeInterval? = nil,
        socksProxy: SOCKSProxy? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.waitsForConnectivity = waitsForConnectivity
        self.resourceTimeout = resourceTimeout
        self.socksProxy = socksProxy
    }

    /// For a background wake and for the outbox, which do their own waiting: 15 s a request.
    public static let quick = SessionPolicy(requestTimeout: 15, waitsForConnectivity: false)
    /// For someone in the app: waits for a network up to two minutes.
    public static let waiting = SessionPolicy(requestTimeout: 15, waitsForConnectivity: true, resourceTimeout: 120)

    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral // Nothing to cache, and no cookies.
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        if let resourceTimeout {
            configuration.timeoutIntervalForResource = resourceTimeout
        }
        if waitsForConnectivity {
            configuration.networkServiceType = .responsiveData
        }
        if let socksProxy, let port = NWEndpoint.Port(rawValue: socksProxy.port) {
            configuration.proxyConfigurations = [
                ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(socksProxy.host), port: port)),
            ]
        }
        return URLSession(configuration: configuration)
    }
}

public struct SOCKSProxy: Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let background: URLSession
    private let foreground: URLSession
    private let isInForeground: @Sendable () async -> Bool

    /// `foreground` while someone is looking at the app, `background` otherwise.
    public init(
        foreground: SessionPolicy = .waiting, background: SessionPolicy = .quick,
        isInForeground: @escaping @Sendable () async -> Bool
    ) {
        self.foreground = foreground.makeSession()
        self.background = background.makeSession()
        self.isInForeground = isInForeground
    }

    /// One policy whatever the app's state: a tailnet read that must fail fast, a short-lived extension.
    public init(policy: SessionPolicy) {
        let session = policy.makeSession()
        foreground = session
        background = session
        isInForeground = { true }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session().data(for: Self.preferringHTTP3(request))
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.notHTTP
        }
        return (data, http)
    }

    /// The session for a request starting now.
    func session() async -> URLSession {
        await isInForeground() ? foreground : background
    }

    /// The Workers are on Cloudflare, which answers HTTP/3: its connections move between Wi-Fi and cellular, where a
    /// TCP one breaks. The system still falls back to HTTP/2.
    public static func preferringHTTP3(_ request: URLRequest) -> URLRequest {
        var request = request
        request.assumesHTTP3Capable = true
        return request
    }
}

/// Tries again, while Jai is in the app, when the network dropped a request that is safe to repeat: a read, or a write
/// carrying `Idempotency-Key`, which makes the server answer a repeat with the first result. Anything else
/// could land twice. A background wake doesn't retry: it has a budget, and the engine goes round again.
///
/// A `503` with a short `Retry-After` is the server asking for exactly that (part of it restarted, as a
/// deploy does): it is repeated after that wait, unseen, on the same terms.
public struct RetryingTransport: HTTPTransport {
    let inner: any HTTPTransport
    var delays: [Duration]
    var isInForeground: @Sendable () async -> Bool
    var sleep: @Sendable (Duration) async throws -> Void

    public init(
        inner: any HTTPTransport,
        delays: [Duration] = [.milliseconds(500), .milliseconds(1_500)],
        isInForeground: @escaping @Sendable () async -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = Outbox.pause
    ) {
        self.inner = inner
        self.delays = delays
        self.isInForeground = isInForeground
        self.sleep = sleep
    }

    /// The longest `Retry-After` repeated here; a longer one is the caller's to show.
    public static let retryAfterMax = 5

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for delay in delays {
            do {
                let answer = try await inner.send(request)
                guard let wait = Self.retryAfter(answer.1), Self.isSafeToRepeat(request), await isInForeground() else {
                    return answer
                }
                try await sleep(.seconds(wait))
            } catch {
                guard Self.isDroppedByNetwork(error), Self.isSafeToRepeat(request), await isInForeground() else {
                    throw error
                }
                // A little jitter, so a phone back on the network doesn't send everything in the same instant.
                try await sleep(delay * Double.random(in: 1...1.5))
            }
        }
        return try await inner.send(request)
    }

    /// The seconds a `503` asks to wait, when it asks for at most `retryAfterMax`.
    public static func retryAfter(_ response: HTTPURLResponse) -> Int? {
        guard response.statusCode == 503,
              let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init),
              (0...retryAfterMax).contains(seconds)
        else {
            return nil
        }
        return seconds
    }

    public static func isSafeToRepeat(_ request: URLRequest) -> Bool {
        (request.httpMethod ?? "GET") == "GET" || request.value(forHTTPHeaderField: "Idempotency-Key") != nil
    }

    public static func isDroppedByNetwork(_ error: any Error) -> Bool {
        let dropped: [URLError.Code] = [
            .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .dataNotAllowed,
        ]
        return (error as? URLError).map { dropped.contains($0.code) } ?? false
    }
}
