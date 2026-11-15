import DurableNetworking
import Foundation
import Synchronization

/// What the network does to one attempt. For demos and tests only: no app links this target.
public enum NetworkCondition: Sendable, Equatable, CustomStringConvertible {
    /// The request goes to the server as it is.
    case normal
    /// No network: the attempt fails at once, as `URLSession` does with no route.
    case offline
    /// The request goes, after this long: a slow or far network.
    case latency(Duration)
    /// The request never answers; the attempt fails as timed out after this long.
    case timeout(after: Duration)
    /// The server answers this status without the request reaching it: a `503` during a deploy, a `429`.
    case status(Int, retryAfter: Int? = nil)
    /// The request reaches the server, which acts on it, and the connection drops before the answer comes back.
    case droppedAfterSend

    public var description: String {
        switch self {
        case .normal: "normal"
        case .offline: "offline"
        case .latency(let wait): "latency \(Self.format(wait))"
        case .timeout(let wait): "timeout after \(Self.format(wait))"
        case .status(let code, let retryAfter): retryAfter.map { "\(code), Retry-After \($0) s" } ?? "\(code)"
        case .droppedAfterSend: "dropped after send"
        }
    }

    private static func format(_ duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}

/// One attempt as it went.
public struct AttemptRecord: Sendable, Identifiable, Equatable {
    public let id: Int
    public let method: String
    public let path: String
    /// The request's `Idempotency-Key`, if it carried one.
    public let key: String?
    public let condition: NetworkCondition
    public let startedAt: Date
    /// How long since the previous attempt with the same key ended: the backoff or `Retry-After` the caller waited.
    public let waited: TimeInterval?
    public internal(set) var endedAt: Date?
    /// The status the caller saw, or nil when it saw an error.
    public internal(set) var status: Int?
    public internal(set) var error: String?
    /// The request reached the server (`normal`, `latency`, `droppedAfterSend`).
    public internal(set) var reachedServer = false

    /// A line for a log: `#3 POST /writes · 503 · 0.01 s`.
    public var summary: String {
        let outcome = status.map(String.init) ?? error ?? "…"
        let took = endedAt.map { String(format: "%.2f s", $0.timeIntervalSince(startedAt)) } ?? "under way"
        let wait = waited.map { String(format: " · waited %.1f s", $0) } ?? ""
        return "#\(id) \(method) /\(path) · \(condition) · \(outcome) · \(took)\(wait)"
    }
}

/// An `HTTPTransport` that applies a `NetworkCondition` to each attempt before (or instead of) handing it to `inner`, and
/// records every attempt. A condition queued with `next(_:)` applies to the next attempts, one each, before the standing
/// one (`set(_:)`) applies again.
public final class FaultInjectingTransport: HTTPTransport, Sendable {
    private struct State {
        var standing: NetworkCondition = .normal
        var queued: [NetworkCondition] = []
        var records: [AttemptRecord] = []
        var nextID = 1
    }

    private let inner: any HTTPTransport
    private let state = Mutex(State())
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let changed: @Sendable () -> Void

    /// `changed` is called after every new record and every update to one.
    public init(
        inner: any HTTPTransport,
        sleep: @escaping @Sendable (Duration) async throws -> Void = Outbox.pause,
        now: @escaping @Sendable () -> Date = { Date() },
        changed: @escaping @Sendable () -> Void = {}
    ) {
        self.inner = inner
        self.sleep = sleep
        self.now = now
        self.changed = changed
    }

    /// The condition from now on, after anything queued. Clears the queue.
    public func set(_ condition: NetworkCondition) {
        state.withLock {
            $0.standing = condition
            $0.queued = []
        }
    }

    /// Conditions for the next attempts, one each, in order.
    public func next(_ conditions: NetworkCondition...) {
        state.withLock { $0.queued += conditions }
    }

    public var standing: NetworkCondition {
        state.withLock { $0.standing }
    }

    public var records: [AttemptRecord] {
        state.withLock { $0.records }
    }

    public func clearRecords() {
        state.withLock { $0.records = [] }
        changed()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (id, condition) = begin(request)
        do {
            let answer = try await perform(request, under: condition, id: id)
            end(id) { $0.status = answer.1.statusCode }
            return answer
        } catch {
            end(id) { $0.error = Self.describe(error) }
            throw error
        }
    }

    private func perform(
        _ request: URLRequest, under condition: NetworkCondition, id: Int
    ) async throws -> (Data, HTTPURLResponse) {
        switch condition {
        case .normal:
            end(id, final: false) { $0.reachedServer = true }
            return try await inner.send(request)
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .latency(let wait):
            try await sleep(wait)
            end(id, final: false) { $0.reachedServer = true }
            return try await inner.send(request)
        case .timeout(let wait):
            try await sleep(wait)
            throw URLError(.timedOut)
        case .status(let code, let retryAfter):
            let headers = retryAfter.map { ["Retry-After": String($0)] } ?? [:]
            let body = Data(#"{"error":{"code":"injected","status":\#(code)}}"#.utf8)
            return (body, Self.response(request, status: code, headers: headers))
        case .droppedAfterSend:
            _ = try await inner.send(request)
            end(id, final: false) { $0.reachedServer = true }
            throw URLError(.networkConnectionLost)
        }
    }

    private func begin(_ request: URLRequest) -> (Int, NetworkCondition) {
        let begun = state.withLock { state -> (Int, NetworkCondition) in
            let condition = state.queued.isEmpty ? state.standing : state.queued.removeFirst()
            let id = state.nextID
            state.nextID += 1
            let key = request.value(forHTTPHeaderField: "Idempotency-Key")
            let started = now()
            let previous = key.flatMap { key in state.records.last { $0.key == key } }
            let waited = previous.map { started.timeIntervalSince($0.endedAt ?? $0.startedAt) }
            state.records.append(AttemptRecord(
                id: id, method: request.httpMethod ?? "GET", path: Self.path(of: request), key: key,
                condition: condition, startedAt: started, waited: waited
            ))
            return (id, condition)
        }
        changed()
        return begun
    }

    private func end(_ id: Int, final: Bool = true, _ change: (inout AttemptRecord) -> Void) {
        let at = now()
        state.withLock { state in
            guard let index = state.records.firstIndex(where: { $0.id == id }) else {
                return
            }
            change(&state.records[index])
            if final {
                state.records[index].endedAt = at
            }
        }
        changed()
    }

    private static func path(of request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private static func response(_ request: URLRequest, status: Int, headers: [String: String]) -> HTTPURLResponse {
        let url = request.url ?? URL(fileURLWithPath: "/")
        // swiftlint:disable:next force_unwrapping
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    static func describe(_ error: any Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        guard let error = error as? URLError else {
            return String(describing: error)
        }
        return switch error.code {
        case .notConnectedToInternet: "offline"
        case .timedOut: "timed out"
        case .networkConnectionLost: "connection lost"
        case .cancelled: "cancelled"
        case .cannotConnectToHost: "cannot connect to host"
        default: "URLError \(error.code.rawValue)"
        }
    }
}
