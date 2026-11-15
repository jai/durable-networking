import DurableNetworking
import DurableNetworkingTesting
import Foundation
import Observation

/// What the demo's server keeps for one item it serves (`GET /items/ID`).
struct DemoItem: Codable, Equatable, Sendable {
    let id: String
    let title: String
}

/// What the server says reached it (`GET /writes`), read past the faults.
struct ServerTruth: Codable, Equatable, Sendable {
    var stored = 0
    var deliveries = 0
}

/// The demo's one object: DurableNetworking's outbox, kept reads and prefetch, over a `FaultInjectingTransport` the
/// buttons drive, against the demo server (Demo/server/demo_server.py). Everything it shows is read back from the
/// package's own state: the outbox's items, the transport's attempts, the inbox's `ReadState`.
@MainActor
@Observable
final class DemoModel {
    static let itemKey = InboxKey("items/demo-1")

    let server: URL
    let faults: FaultInjectingTransport
    private(set) var attempts: [AttemptRecord] = []
    private(set) var outboxItems: [OutboxItem] = []
    private(set) var underWay: Set<String> = []
    private(set) var results: [String] = []
    private(set) var truth = ServerTruth()
    private(set) var truthError: String?
    private(set) var prefetchResult: String?
    private(set) var item: Inbox<DemoItem>?
    private(set) var condition: String = NetworkCondition.normal.description
    private(set) var sent = 0

    @ObservationIgnored private let truthTransport = URLSessionTransport(policy: .quick)
    @ObservationIgnored private let store: ReadStore
    @ObservationIgnored private let inboxes: Inboxes
    @ObservationIgnored private let outboxFile: URL
    // Made in init after `self` is usable: its hooks call back here.
    // swiftlint:disable:next implicitly_unwrapped_optional
    @ObservationIgnored private var outbox: Outbox!
    @ObservationIgnored private var revision = -1
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// `reset` starts clean: no outbox file, no kept reads, and the server forgets everything.
    init(server: URL, directory: URL, reset: Bool) {
        self.server = server
        outboxFile = directory.appending(path: "outbox.json")
        store = ReadStore(directory: directory.appending(path: "reads"))
        inboxes = Inboxes(store: store)
        if reset {
            try? FileManager.default.removeItem(at: outboxFile)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let box = WeakBox()
        faults = FaultInjectingTransport(inner: URLSessionTransport(policy: .quick), changed: {
            _ = Task { @MainActor in box.model?.attemptsChanged() }
        })
        var hooks = Outbox.Hooks()
        hooks.changed = { _ = Task { @MainActor in await box.model?.outboxChanged() } }
        hooks.accepted = { item, _ in
            _ = Task { @MainActor in box.model?.note("\(item.id) accepted after \(item.attempts + 1) attempts") }
        }
        hooks.rejected = { item, why in _ = Task { @MainActor in box.model?.note("\(item.id) refused: \(why)") } }
        outbox = Outbox(file: outboxFile, hooks: hooks, attempt: Self.attempt(server: server, transport: faults))
        box.model = self
        Task {
            if reset {
                await resetServer()
            }
            await outbox.start()
            await outboxChanged()
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readTruth()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Conditions

    func set(_ condition: NetworkCondition) {
        faults.set(condition)
        conditionChanged()
    }

    func next(_ conditions: NetworkCondition...) {
        for condition in conditions {
            faults.next(condition)
        }
        conditionChanged()
    }

    /// The network is back: normal from now on, and everything waiting goes at once, as `PathWatcher` makes an app do.
    func backOnline() async {
        note("back online")
        faults.set(.normal)
        conditionChanged()
        await outbox.kick()
        await inboxes.retryFailed()
    }

    // MARK: - Writes

    /// A write, saved before anything is sent; the outbox sends it until the server has it.
    func sendWrite() async {
        sent += 1
        let id = "w-\(sent)-\(UUID().uuidString.prefix(4).lowercased())"
        let body = Data(#"{"text":"Write \#(sent)"}"#.utf8)
        do {
            try await outbox.enqueue(OutboxItem(id: id, lane: "demo", path: "writes", body: body, createdAt: Date()))
            note("\(id) saved")
        } catch {
            note("\(id) not saved: \(error.localizedDescription)")
        }
    }

    // MARK: - Reads

    /// Loads the item into the store, as a notification service does when a push names it.
    func prefetch() async {
        do {
            let answer = try await Prefetcher(store: store, transport: faults).load(
                Self.itemKey, request: itemRequest(), validate: { _ = try JSONDecoder().decode(DemoItem.self, from: $0) }
            )
            prefetchResult = "prefetched at \(answer.savedAt.formatted(date: .omitted, time: .standard))"
        } catch {
            prefetchResult = "prefetch failed: \(error)"
        }
    }

    /// Opens the item as a screen does: what is kept at once, then a refresh.
    func openItem() async {
        let request = itemRequest()
        let faults = faults
        let inbox = inboxes.inbox(
            Self.itemKey, decode: { try JSONDecoder().decode(DemoItem.self, from: $0) },
            fetch: {
                let (data, response) = try await faults.send(request)
                guard (200..<300).contains(response.statusCode) else {
                    throw ReadFailure.refused(status: response.statusCode, reason: "server answered")
                }
                return data
            }
        )
        item = inbox
        await inbox.refresh()
    }

    /// Forgets the open item, so the next open starts from the store, as a relaunch does.
    func closeItem() {
        item = nil
    }

    // MARK: - Updates

    private func attemptsChanged() {
        attempts = faults.records
    }

    private func conditionChanged() {
        condition = faults.standing.description
    }

    private func outboxChanged() async {
        let state = await outbox.state
        guard state.revision > revision else {
            return
        }
        revision = state.revision
        outboxItems = state.items
        underWay = state.underWay
    }

    private func note(_ line: String) {
        results.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
    }

    private func readTruth() async {
        var request = URLRequest(url: server.appending(path: "writes"))
        request.timeoutInterval = 2
        do {
            let (data, _) = try await truthTransport.send(request)
            truth = try JSONDecoder().decode(ServerTruth.self, from: data)
            truthError = nil
        } catch {
            truthError = "server unreachable at \(server.absoluteString)"
        }
    }

    private func resetServer() async {
        var request = URLRequest(url: server.appending(path: "reset"))
        request.httpMethod = "POST"
        _ = try? await truthTransport.send(request)
    }

    private func itemRequest() -> URLRequest {
        URLRequest(url: server.appending(path: "items/demo-1"))
    }

    private nonisolated static func attempt(server: URL, transport: any HTTPTransport) -> Outbox.Attempt {
        { item in
            var request = URLRequest(url: server.appending(path: item.path))
            request.httpMethod = item.method
            request.httpBody = item.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(item.id, forHTTPHeaderField: "Idempotency-Key")
            do {
                let (data, response) = try await transport.send(request)
                return .of(
                    data: data, response: response,
                    isValid: { (try? JSONSerialization.jsonObject(with: $0)) != nil },
                    rejection: { status, _ in "server answered \(status)" }
                )
            } catch {
                return .of(error: error)
            }
        }
    }
}

/// Lets the transport's and the outbox's callbacks, made before the model is, reach it.
@MainActor
private final class WeakBox: Sendable {
    weak var model: DemoModel?
}
