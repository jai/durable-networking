import Foundation
import os

/// Gives outbox items to a background `URLSession`, which the system runs after the app is suspended or killed. The
/// system waits for a network by itself. It treats a transfer started from the background as discretionary, so items
/// are handed over while the app is still in the foreground, as it leaves.
///
/// Every item carries its idempotency key, so one that also goes out from the foreground lands once.
public final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Builds the signed request for an item. `nil` skips it, for example with no secret to send.
    public typealias MakeRequest = @Sendable (OutboxItem) async -> URLRequest?
    /// An upload ended: with the server's answer, or with `nil` if the network beat the system too.
    public typealias Answered = @Sendable (String, Data?, HTTPURLResponse?) async -> Void

    private let makeRequest: MakeRequest
    private let answered: Answered
    private let directory: URL
    private let logger: Logger
    private let lock = NSLock()
    private var received: [Int: Data] = [:]
    private var finishEvents: (@Sendable () -> Void)?
    private var session: URLSession!

    /// `logSubsystem` is the app's, so its uploads log beside its outbox.
    public init(
        identifier: String, logSubsystem: String, directory: URL, request: @escaping MakeRequest,
        answered: @escaping Answered
    ) {
        logger = Logger(subsystem: logSubsystem, category: "uploads")
        makeRequest = request
        self.answered = answered
        self.directory = directory
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = Outbox.maxAge
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Starts an upload for each item not already with the system.
    public func handOff(_ items: [OutboxItem]) async {
        let underWay = Set(await session.allTasks.compactMap(\.taskDescription))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in items where item.rejection == nil && !underWay.contains(item.id) {
            guard let request = await makeRequest(item) else {
                continue
            }
            let body = directory.appending(path: "\(item.id).body")
            // An upload must come from a file. Reply words are as protected here as in the outbox.
            #if os(iOS)
            guard (try? item.body.write(to: body, options: .completeFileProtectionUntilFirstUserAuthentication)) != nil
            else { continue }
            #else
            guard (try? item.body.write(to: body)) != nil else { continue }
            #endif
            let task = session.uploadTask(with: request, fromFile: body)
            task.taskDescription = item.id
            task.resume()
            logger.notice("handed over \(item.id, privacy: .public)")
        }
    }

    /// Takes an item back from the system. Its answer no longer matters, and a late copy could undo a later write.
    public func cancel(id: String) async {
        await session.allTasks.first { $0.taskDescription == id }?.cancel()
    }

    /// The ids the system is holding.
    public func ids() async -> Set<String> {
        Set(await session.allTasks.compactMap(\.taskDescription))
    }

    /// For a launch or wake the system made for this session's events: `done` runs when they have all arrived.
    public func onFinishedEvents(_ done: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = done }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let data = lock.withLock { received.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let id = task.taskDescription else {
            return
        }
        try? FileManager.default.removeItem(at: directory.appending(path: "\(id).body"))
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        logger.notice("""
            upload ended \(id, privacy: .public) status=\(status) error=\(String(describing: error), privacy: .public)
            """)
        let answered = answered
        let response = error == nil ? task.response as? HTTPURLResponse : nil
        Task { await answered(id, response == nil ? nil : data, response) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = lock.withLock {
            defer { finishEvents = nil }
            return finishEvents
        }
        done?()
    }
}
