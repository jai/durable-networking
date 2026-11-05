import Foundation

/// One write Jai has made, saved until the server has it. `id` is the idempotency key: every attempt carries it, so a
/// repeat the server already took comes back as the first result.
public struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// Items in one lane go in order; lanes don't wait for each other.
    public let lane: String
    public let method: String
    public let path: String
    public let body: Data
    public let createdAt: Date
    public internal(set) var attempts = 0
    public internal(set) var lastError: String?
    /// Why the server refused it. It stays, for Jai to retry or cancel, and is not sent again by itself.
    public internal(set) var rejection: String?
    var nextAttemptAt: Date

    public init(id: String, lane: String, method: String = "POST", path: String, body: Data, createdAt: Date) {
        self.id = id
        self.lane = lane
        self.method = method
        self.path = path
        self.body = body
        self.createdAt = createdAt
        nextAttemptAt = createdAt
    }

    /// Builds 133 and 134 wrote replies with no `method`. They were all POST.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        lane = try container.decode(String.self, forKey: .lane)
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "POST"
        path = try container.decode(String.self, forKey: .path)
        body = try container.decode(Data.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attempts = try container.decode(Int.self, forKey: .attempts)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        rejection = try container.decodeIfPresent(String.self, forKey: .rejection)
        nextAttemptAt = try container.decode(Date.self, forKey: .nextAttemptAt)
    }
}

/// What one attempt came to.
public enum OutboxVerdict: Equatable, Sendable {
    /// The server holds it; its answer.
    case accepted(Data)
    /// Nothing is known, or the server asked for patience: send again.
    case retry(String, after: Duration? = nil)
    /// The server refused it, and would again.
    case rejected(String)

    /// Turns a response into a verdict. `isValid` reads a 2xx body: a captive portal answers 200 with its own page.
    public static func of(
        data: Data, response: HTTPURLResponse, isValid: (Data) -> Bool, rejection: (Int, Data) -> String
    ) -> OutboxVerdict {
        let status = response.statusCode
        switch status {
        case 200..<300:
            return isValid(data) ? .accepted(data) : .retry("unreadable answer")
        case 408, 425, 429, 500...599:
            let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map(Duration.seconds)
            return .retry("server answered \(status)", after: after)
        default:
            return .rejected(rejection(status, data))
        }
    }

    public static func of(error: any Error) -> OutboxVerdict {
        error is CancellationError ? .retry("cancelled") : .retry(error.localizedDescription)
    }
}

/// Exponential backoff with full jitter.
public struct OutboxBackoff: Sendable {
    public var base: Duration = .seconds(1)
    public var cap: Duration = .seconds(10)
    public var floor: Duration = .milliseconds(250)
    /// In `0...1`; a test passes a constant.
    public var random: @Sendable () -> Double = { Double.random(in: 0...1) }

    public init() {}

    func delay(afterAttempt attempt: Int) -> Duration {
        let ceiling = min(cap, base * pow(2, Double(min(attempt - 1, 16))))
        return max(floor, ceiling * random())
    }
}

/// A persistent queue of writes (the transactional outbox pattern). `enqueue` returns once the item is on disk; only
/// then does anything go on the network. It leaves the file only after the server has answered, so a killed process
/// or a lost answer sends it again, and the idempotency key makes that harmless.
public actor Outbox {
    public typealias Attempt = @Sendable (OutboxItem) async -> OutboxVerdict

    public struct Hooks: Sendable {
        /// The server holds the item. Called before it leaves the file.
        public var accepted: @Sendable (OutboxItem, Data) async -> Void = { _, _ in }
        /// The server refused it.
        public var rejected: @Sendable (OutboxItem, String) async -> Void = { _, _ in }
        /// The queue changed; read `state`. Announcements can arrive out of order, so they carry nothing.
        public var changed: @Sendable () async -> Void = {}
        public init() {}
    }

    public static let maxAge: TimeInterval = 24 * 3600

    public typealias Reader = @Sendable (URL) throws -> Data

    private let file: URL?
    private let read: Reader
    private let attempt: Attempt
    private let backoff: OutboxBackoff
    private let hooks: Hooks
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var items: [OutboxItem] = []
    /// An attempt under way.
    private struct Run {
        let id: String
        let task: Task<Void, Never>
    }

    private var running: [String: Run] = [:]
    /// Ids the server has accepted whose hook is still running. They stay in the file, so a kill sends them again, but this
    /// process doesn't.
    private var answered: Set<String> = []
    private var timer: Task<Void, Never>?
    private var started = false
    /// The file can't be read or written yet: a launch before the first unlock after a reboot. Items wait in memory, and
    /// nothing is written over the file until it can be read.
    private var sealed = false

    public init(
        file: URL?,
        backoff: OutboxBackoff = OutboxBackoff(),
        hooks: Hooks = Hooks(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        read: @escaping Reader = { try Data(contentsOf: $0) },
        attempt: @escaping Attempt
    ) {
        self.file = file
        self.read = read
        self.backoff = backoff
        self.hooks = hooks
        self.now = now
        self.sleep = sleep ?? Outbox.pause
        self.attempt = attempt
        if let held = Self.load(file, read: read) {
            items = held
        } else {
            sealed = true
        }
    }

    /// `Task.sleep(for:)` passed as a closure aborts the process under Swift 6.3 ("freed pointer was not the last
    /// allocation"); this one does not.
    @Sendable public static func pause(_ wait: Duration) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, wait.seconds) * 1e9))
    }

    public var snapshot: [OutboxItem] { items }

    /// The items, and the ids with an attempt under way.
    public var state: (items: [OutboxItem], underWay: Set<String>) {
        (items, Set(running.values.map(\.id)))
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Begins sending what the file holds. Nothing goes out before this, so the app can load first.
    public func start() {
        started = true
        pump()
    }

    /// Saves the item, then sends it. Throws, with nothing queued, if it can't be saved. The same `id` again does nothing.
    /// Before the first unlock nothing can be saved, so it waits in memory until the file opens.
    public func enqueue(_ item: OutboxItem) throws {
        openSealedFile()
        guard !items.contains(where: { $0.id == item.id }) else {
            return
        }
        do {
            try save(items + [item])
        } catch CocoaError.fileWriteNoPermission {
            sealed = true
        }
        items.append(item)
        announce()
        pump()
    }

    /// The network came back, or Jai did: stop waiting. An attempt under way is probably stuck on the old path, so it is
    /// abandoned and made again. The key makes that safe.
    public func kick() {
        for index in items.indices where items[index].rejection == nil {
            items[index].nextAttemptAt = now()
        }
        for (_, run) in running {
            run.task.cancel()
        }
        running.removeAll()
        pump()
    }

    /// Jai gave up on it. One already on the wire may still land.
    public func cancel(id: String) {
        running.first { $0.value.id == id }.map {
            $0.value.task.cancel()
            running[$0.key] = nil
        }
        remove(id)
        pump()
    }

    /// Takes the answer of an attempt made elsewhere, such as a background upload.
    public func settle(id: String, _ verdict: OutboxVerdict) async {
        guard let item = items.first(where: { $0.id == id }) else {
            return
        }
        if let run = running[item.lane], run.id == id {
            run.task.cancel()
            running[item.lane] = nil
        }
        await apply(verdict, to: item)
    }

    private func pump() {
        guard started else {
            return
        }
        openSealedFile()
        let current = now()
        for (index, item) in items.enumerated()
        where item.rejection == nil && current.timeIntervalSince(item.createdAt) >= Self.maxAge {
            let why = "Not sent after 24 hours"
            items[index].rejection = why
            let rejected = hooks.rejected
            Task { await rejected(item, why) }
        }
        var lanesSeen: Set<String> = []
        var soonest: Date?
        for item in items where item.rejection == nil && lanesSeen.insert(item.lane).inserted {
            guard running[item.lane] == nil, !answered.contains(item.id) else {
                continue
            }
            // Not `<=` on `Date`: built with Xcode 27.2 it needs a Foundation symbol macOS 27.2 doesn't have.
            if item.nextAttemptAt.timeIntervalSince(current) <= 0 {
                launch(item)
            } else {
                let earlier = soonest.map { $0.timeIntervalSince(item.nextAttemptAt) <= 0 } ?? false
                soonest = earlier ? soonest : item.nextAttemptAt
            }
        }
        announce()
        timer?.cancel()
        timer = soonest.map { when in
            let wait = Duration.seconds(max(0, when.timeIntervalSince(current)))
            let sleep = sleep
            return Task { [weak self] in
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
                await self?.pump()
            }
        }
    }

    private func launch(_ item: OutboxItem) {
        let attempt = attempt
        running[item.lane] = Run(id: item.id, task: Task { [weak self] in
            let verdict = await attempt(item)
            guard !Task.isCancelled else {
                return
            }
            await self?.finish(item, verdict)
        })
    }

    private func finish(_ item: OutboxItem, _ verdict: OutboxVerdict) async {
        running[item.lane] = nil
        await apply(verdict, to: item)
    }

    private func apply(_ verdict: OutboxVerdict, to item: OutboxItem) async {
        switch verdict {
        case .accepted(let data):
            answered.insert(item.id)
            await hooks.accepted(item, data)
            answered.remove(item.id)
            remove(item.id)
        case .rejected(let why):
            update(item.id) {
                $0.attempts += 1
                $0.rejection = why
            }
            await hooks.rejected(item, why)
        case .retry(let why, let after):
            update(item.id) {
                $0.attempts += 1
                $0.lastError = why
                let wait = max(after ?? .zero, backoff.delay(afterAttempt: $0.attempts))
                $0.nextAttemptAt = now().addingTimeInterval(wait.seconds)
            }
        }
        pump()
    }

    private func update(_ id: String, _ change: (inout OutboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&items[index])
        try? save(items)
    }

    private func remove(_ id: String) {
        items.removeAll { $0.id == id }
        try? save(items)
        announce()
    }

    private func announce() {
        let changed = hooks.changed
        Task { await changed() }
    }

    private func openSealedFile() {
        guard sealed, let held = Self.load(file, read: read) else {
            return
        }
        sealed = false
        items = held.filter { kept in !items.contains { $0.id == kept.id } } + items
        try? save(items)
        announce()
    }

    private func save(_ items: [OutboxItem]) throws {
        guard let file, !sealed else {
            return
        }
        let data = try JSONEncoder().encode(items)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // A notification's Reply can arrive with the phone locked.
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    /// What the file holds, or `nil` while it can't be read. A file that can't be decoded is kept beside the new one,
    /// not sent and not lost.
    private static func load(_ file: URL?, read: Reader) -> [OutboxItem]? {
        guard let file else {
            return []
        }
        let data: Data
        do {
            data = try read(file)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }
        if let items = try? JSONDecoder().decode([OutboxItem].self, from: data) {
            return items
        }
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
        return []
    }
}

extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
