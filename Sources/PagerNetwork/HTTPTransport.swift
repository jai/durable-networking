import Foundation

/// Sends one request. `RetryingTransport` over `URLSessionTransport` in the app; a scripted stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Equatable {
    case notHTTP
}

public struct URLSessionTransport: HTTPTransport {
    /// For a background wake and for the outbox, which do their own waiting: 15 s a request.
    private let quick: URLSession
    /// For Jai in the app: a request made with no network waits for one, up to `waitLimit`, so an elevator delays it
    /// and doesn't fail it.
    private let waiting: URLSession
    private let isInForeground: @Sendable () async -> Bool

    private static let waitLimit: TimeInterval = 120

    private static func makeSession(waits: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral // Nothing to cache, and no cookies.
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = waits
        if waits {
            configuration.timeoutIntervalForResource = waitLimit
            configuration.networkServiceType = .responsiveData
        }
        return URLSession(configuration: configuration)
    }

    public init(isInForeground: @escaping @Sendable () async -> Bool) {
        quick = Self.makeSession(waits: false)
        waiting = Self.makeSession(waits: true)
        self.isInForeground = isInForeground
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session().data(for: Self.preferringHTTP3(request))
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.notHTTP
        }
        return (data, http)
    }

    /// The session for a request starting now.
    public func session() async -> URLSession {
        await isInForeground() ? waiting : quick
    }

    /// Both Workers are on Cloudflare, which answers HTTP/3: its connections move between Wi-Fi and cellular, where a
    /// TCP one breaks. The system still falls back to HTTP/2.
    public static func preferringHTTP3(_ request: URLRequest) -> URLRequest {
        var request = request
        request.assumesHTTP3Capable = true
        return request
    }
}

/// Tries again, while Jai is in the app, when the network dropped a request that is safe to repeat: a read, or a write
/// carrying `Idempotency-Key`, whose `client_ref` makes the Worker answer a repeat with the first result. Anything else
/// could land twice. A background wake doesn't retry: it has a budget, and the engine goes round again.
///
/// A `503` with a short `Retry-After` is the Worker asking for exactly that (`try_again`: part of it restarted, as a
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
