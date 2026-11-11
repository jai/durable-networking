import Foundation
import Observation

/// Every read on screen, the store they keep their answers in, and whether there is a network. When a network appears,
/// or Jai comes back to the app, each read whose last attempt failed goes again.
@MainActor
@Observable
public final class Inboxes {
    public private(set) var isOnline = true

    @ObservationIgnored private let store: ReadStore?
    @ObservationIgnored private let classify: @Sendable (any Error) -> ReadFailure
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var live: [InboxKey: Entry] = [:]
    @ObservationIgnored private var watcher: PathWatcher?

    private final class Entry {
        weak var inbox: (any Retryable)?
        init(_ inbox: any Retryable) { self.inbox = inbox }
    }

    /// `store` `nil` keeps nothing between launches. `classify` turns the app's errors into failures; it gets the
    /// error as `fetch` threw it.
    /// Not on the main actor, so the sync engine, which is not, can own the app's one.
    public nonisolated init(
        store: ReadStore?,
        classify: @escaping @Sendable (any Error) -> ReadFailure = ReadFailure.of,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.classify = classify
        self.now = now
    }

    /// Follows the network from now on.
    public func watchNetwork() {
        guard watcher == nil else {
            return
        }
        watcher = PathWatcher(
            satisfied: { [weak self] isUp in Task { @MainActor in self?.isOnline = isUp } },
            returned: { [weak self] in Task { @MainActor in await self?.retryFailed() } }
        )
    }

    /// The read for `key`: the one already made while it is still in use, else a new one opened on what is kept.
    public func inbox<Value: Sendable>(
        _ key: InboxKey, decode: @escaping Inbox<Value>.Decode, fetch: @escaping Inbox<Value>.Fetch
    ) -> Inbox<Value> {
        if let made = live[key]?.inbox as? Inbox<Value> {
            return made
        }
        let made = Inbox(key: key, store: store, classify: classify, now: now, decode: decode, fetch: fetch)
        live = live.filter { $0.value.inbox != nil }
        live[key] = Entry(made)
        return made
    }

    /// The network came back, or Jai did: every read whose last attempt failed goes again, side by side.
    public func retryFailed() async {
        let reads = live.values.compactMap(\.inbox).map { inbox in Task { await inbox.retryIfFailed() } }
        for read in reads {
            await read.value
        }
    }
}
