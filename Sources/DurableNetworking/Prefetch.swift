import Foundation

/// Loads one read into the store ahead of the screen that shows it: a push names a thread or a PR, and the
/// notification service or a background fetch keeps its data, so it opens offline. The `Inbox` for the same key opens
/// on what is kept here. Not on the main actor, so an app extension can use it.
public struct Prefetcher: Sendable {
    public let store: ReadStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(store: ReadStore, transport: any HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    /// Sends `request` and keeps its body under `key` when it is a 2xx that `validate` accepts, so a captive portal's
    /// page never replaces good data. Throws `ReadFailure`, so the caller can log why.
    @discardableResult
    public func load(
        _ key: InboxKey, request: URLRequest, validate: @Sendable (Data) throws -> Void
    ) async throws -> KeptAnswer {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ReadFailure.of(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ReadFailure.refused(
                status: response.statusCode, reason: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            )
        }
        do {
            try validate(data)
        } catch {
            throw ReadFailure.unreadable
        }
        let answer = KeptAnswer(data: data, savedAt: now())
        try store.save(answer, for: key)
        return answer
    }
}
