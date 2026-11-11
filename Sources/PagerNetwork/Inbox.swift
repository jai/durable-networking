import Foundation
import Observation

/// Something an `Inboxes` can ask to try again.
@MainActor
protocol Retryable: AnyObject, Sendable {
    func retryIfFailed() async
}

/// One read on screen (the outbox's twin). It opens with what the store kept, at once, then refreshes in the background;
/// a refresh that fails keeps the data and says why. Made by `Inboxes`, one per key.
@MainActor
@Observable
public final class Inbox<Value: Sendable>: Retryable {
    public typealias Fetch = @Sendable () async throws -> Data
    public typealias Decode = @Sendable (Data) throws -> Value

    public private(set) var state: ReadState<Value> = .empty
    /// A read is under way. Separate from `state`, so what is on screen stays while it runs.
    public private(set) var isRefreshing = false
    public let key: InboxKey

    @ObservationIgnored private let source: Source<Value>
    @ObservationIgnored private var running: Task<Void, Never>?

    init(
        key: InboxKey, store: ReadStore?, classify: @escaping @Sendable (any Error) -> ReadFailure,
        now: @escaping @Sendable () -> Date, decode: @escaping Decode, fetch: @escaping Fetch
    ) {
        self.key = key
        source = Source(key: key, store: store, classify: classify, now: now, decode: decode, fetch: fetch)
        // A kept answer a newer build can't decode is as good as none; the next read replaces it.
        if let kept = store?.load(key), let value = try? decode(kept.data) {
            state = state.after(.kept(value, savedAt: kept.savedAt))
        }
    }

    /// Reads now. A second call while one is under way waits for that one rather than sending another.
    public func refresh() async {
        if let running {
            await running.value
            return
        }
        isRefreshing = true
        let task = Task { [source] in
            let event = await source.read()
            self.state = self.state.after(event)
        }
        running = task
        await task.value
        running = nil
        isRefreshing = false
    }

    /// The server answered this another way, such as a write's response: it is the newest copy.
    public func take(_ data: Data) throws {
        let value = try source.decode(data)
        let readAt = source.now()
        state = state.after(.answered(value, readAt: readAt))
        try? source.store?.save(KeptAnswer(data: data, savedAt: readAt), for: key)
    }

    /// The server no longer has it: a `404` for a deleted list or chat.
    public func forget() {
        state = state.after(.forgotten)
        source.store?.remove(key)
    }

    func retryIfFailed() async {
        guard state.failure != nil else {
            return
        }
        await refresh()
    }
}

/// Where one read's answers come from and go.
private struct Source<Value: Sendable>: Sendable {
    let key: InboxKey
    let store: ReadStore?
    let classify: @Sendable (any Error) -> ReadFailure
    let now: @Sendable () -> Date
    let decode: Inbox<Value>.Decode
    let fetch: Inbox<Value>.Fetch

    /// Off the main actor: the request, the decode and the write.
    func read() async -> ReadEvent<Value> {
        let data: Data
        do {
            data = try await fetch()
        } catch {
            return .failed(classify(error))
        }
        let value: Value
        do {
            value = try decode(data)
        } catch {
            return .failed(.unreadable)
        }
        let readAt = now()
        // Not keeping it costs the next launch's head start, not this answer.
        try? store?.save(KeptAnswer(data: data, savedAt: readAt), for: key)
        return .answered(value, readAt: readAt)
    }
}
