@testable import DurableNetworking
import Foundation
import Testing

/// Attempts answered from a script, one verdict at a time, recording what went out.
private actor Script {
    var verdicts: [OutboxVerdict]
    var sent: [String] = []
    var fileExisted: [Bool] = []
    var waiting: [CheckedContinuation<Void, Never>] = []
    let file: URL?

    init(_ verdicts: [OutboxVerdict], file: URL? = nil) {
        self.verdicts = verdicts
        self.file = file
    }

    func next(_ item: OutboxItem) -> OutboxVerdict {
        sent.append(item.id)
        if let file {
            fileExisted.append(FileManager.default.fileExists(atPath: file.path))
        }
        return verdicts.isEmpty ? .accepted(Data("{}".utf8)) : verdicts.removeFirst()
    }
}

/// Holds `gate`-listed ids until `open()`, as a request stuck on a dead path does.
private actor Gate {
    var held: Set<String>
    var began: [String] = []
    var finished: [String] = []
    init(_ held: Set<String>) { self.held = held }
    func begin(_ id: String) { began.append(id) }
    func finish(_ id: String) { finished.append(id) }
    func isHeld(_ id: String) -> Bool { held.contains(id) }
    func open() { held.removeAll() }
}

private func item(_ id: String, lane: String = "a", createdAt: Date = Date()) -> OutboxItem {
    OutboxItem(id: id, lane: lane, path: "device/threads/replies", body: Data("{}".utf8), createdAt: createdAt)
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString)/outbox.json")
}

private var noWaiting: OutboxBackoff {
    var backoff = OutboxBackoff()
    backoff.base = .milliseconds(1)
    backoff.cap = .milliseconds(1)
    backoff.floor = .milliseconds(1)
    return backoff
}

private func settled(_ outbox: Outbox, within limit: Duration = .seconds(5)) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while clock.now < end {
        if await outbox.isEmpty {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func until(within limit: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while clock.now < end {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

struct OutboxTests {
    @Test func itIsOnDiskBeforeAnythingGoesOut() async throws {
        let file = tempFile()
        let script = Script([], file: file)
        let outbox = Outbox(file: file, backoff: noWaiting) { await script.next($0) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        #expect(await settled(outbox))
        #expect(await script.fileExisted == [true])
    }

    @Test func nothingGoesOutBeforeStart() async throws {
        let script = Script([])
        let outbox = Outbox(file: nil, backoff: noWaiting) { await script.next($0) }
        try await outbox.enqueue(item("r1"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await script.sent.isEmpty)
    }

    @Test func aNewProcessFinishesWhatTheLastOneLeft() async throws {
        let file = tempFile()
        let killed = Outbox(file: file) { _ in .retry("the process is about to die", after: .seconds(600)) }
        await killed.start()
        try await killed.enqueue(item("r1"))
        #expect(await until { await killed.snapshot.first?.attempts == 1 })

        let script = Script([])
        let next = Outbox(file: file, backoff: noWaiting) { await script.next($0) }
        #expect(await next.snapshot.map(\.id) == ["r1"])
        // No kick: a new process sends at once, whatever backoff the last one had reached.
        await next.start()
        #expect(await settled(next))
        #expect(await script.sent == ["r1"])
        let reopened = Outbox(file: file) { _ in .accepted(Data()) }
        #expect(await reopened.isEmpty)
    }

    @Test func itKeepsTheSameKeyUntilTheServerAnswers() async throws {
        let script = Script([.retry("lost"), .retry("timed out"), .retry("503"), .accepted(Data("{}".utf8))])
        let outbox = Outbox(file: nil, backoff: noWaiting) { await script.next($0) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        #expect(await settled(outbox))
        #expect(await script.sent == ["r1", "r1", "r1", "r1"])
    }

    @Test func enqueuingTheSameIDTwiceSendsOnce() async throws {
        let script = Script([.retry("wait", after: .milliseconds(20))])
        let outbox = Outbox(file: nil, backoff: noWaiting) { await script.next($0) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        try await outbox.enqueue(item("r1"))
        #expect(await outbox.snapshot.count == 1)
        #expect(await settled(outbox))
        #expect(await script.sent == ["r1", "r1"])
    }

    @Test func aRefusalStopsItKeepsItAndLetsTheNextGo() async throws {
        let script = Script([.rejected("no such thread")])
        let outbox = Outbox(file: nil, backoff: noWaiting) { await script.next($0) }
        await outbox.start()
        try await outbox.enqueue(item("bad"))
        try await outbox.enqueue(item("good"))
        #expect(await until { await outbox.snapshot.count == 1 })
        #expect(await outbox.snapshot.first?.id == "bad")
        #expect(await outbox.snapshot.first?.rejection == "no such thread")
        await outbox.kick()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await script.sent == ["bad", "good"], "a kick does not resend a refusal")
    }

    @Test func aLaneKeepsItsOrderAndOtherLanesDoNotWaitForIt() async throws {
        let gate = Gate(["a1"])
        let outbox = Outbox(file: nil, backoff: noWaiting) { item in
            await gate.begin(item.id)
            while await gate.isHeld(item.id) {
                try? await Task.sleep(for: .milliseconds(2))
                if Task.isCancelled {
                    return .retry("cancelled")
                }
            }
            await gate.finish(item.id)
            return .accepted(Data())
        }
        await outbox.start()
        try await outbox.enqueue(item("a1", lane: "a"))
        try await outbox.enqueue(item("a2", lane: "a"))
        try await outbox.enqueue(item("b1", lane: "b"))
        #expect(await until { await gate.finished.contains("b1") })
        #expect(await !gate.began.contains("a2"))
        await gate.open()
        #expect(await settled(outbox))
        #expect(await gate.finished == ["b1", "a1", "a2"])
    }

    @Test func aKickAbandonsAStuckAttemptAndSkipsTheWait() async throws {
        let gate = Gate(["r1"])
        let outbox = Outbox(file: nil, backoff: noWaiting) { item in
            await gate.begin(item.id)
            if await gate.isHeld(item.id) {
                await gate.open() // Only the first attempt sticks.
                try? await Task.sleep(for: .seconds(60))
                return .retry("timed out")
            }
            return .accepted(Data())
        }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        #expect(await until { await gate.began.count == 1 })
        await outbox.kick()
        #expect(await settled(outbox, within: .seconds(2)))
        #expect(await gate.began == ["r1", "r1"])
    }

    @Test func aKickCutsABackoffShort() async throws {
        let script = Script([.retry("down", after: .seconds(600))])
        let outbox = Outbox(file: nil) { await script.next($0) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        #expect(await until { await outbox.snapshot.first?.attempts == 1 })
        await outbox.kick()
        #expect(await settled(outbox, within: .seconds(2)))
    }

    @Test func retryAfterIsObeyed() async throws {
        let waits = Waits()
        let script = Script([.retry("429", after: .seconds(40))])
        let outbox = Outbox(
            file: nil,
            sleep: { await waits.add($0); try await Task.sleep(for: .seconds(600)) },
            attempt: { await script.next($0) }
        )
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        #expect(await until { await waits.all.first != nil })
        let wait = try #require(await waits.all.first)
        #expect(wait > .seconds(39) && wait <= .seconds(40))
    }

    @Test func cancelTakesItOutOfTheFile() async throws {
        let file = tempFile()
        let outbox = Outbox(file: file) { _ in .retry("down", after: .seconds(600)) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        await outbox.cancel(id: "r1")
        let reopened = Outbox(file: file) { _ in .accepted(Data()) }
        #expect(await reopened.isEmpty)
    }

    @Test func afterADayItStopsAndSaysSo() async throws {
        let script = Script([])
        let day = Date(timeIntervalSinceNow: -Outbox.maxAge - 1)
        let outbox = Outbox(file: nil, backoff: noWaiting) { await script.next($0) }
        try await outbox.enqueue(item("old", createdAt: day))
        await outbox.start()
        #expect(await outbox.snapshot.first?.rejection == "Not sent after 24 hours")
        #expect(await script.sent.isEmpty)
    }

    @Test func aFileItCannotReadIsKeptBeside() async throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let outbox = Outbox(file: file) { _ in .accepted(Data()) }
        #expect(await outbox.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("unreadable").path))
    }

    /// Builds 133 and 134 wrote this shape. A decode failure would set their queued replies aside.
    @Test func aFileWithNoMethodStillLoadsAndSendsAsAPost() async throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date().timeIntervalSinceReferenceDate
        try Data("""
        [{"id":"r1","lane":"a","path":"device/threads/replies","body":"e30=","createdAt":\(now),"attempts":2,
          "lastError":"down","nextAttemptAt":\(now)}]
        """.utf8).write(to: file)
        let script = Script([])
        let outbox = Outbox(file: file, backoff: noWaiting) { await script.next($0) }
        let loaded = try #require(await outbox.snapshot.first)
        #expect(loaded.method == "POST" && loaded.attempts == 2 && loaded.lastError == "down")
        #expect(loaded.body == Data("{}".utf8))
        await outbox.start()
        #expect(await settled(outbox))
        #expect(await script.sent == ["r1"])
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("unreadable").path))
    }

    @Test func theMethodSurvivesTheFile() async throws {
        let file = tempFile()
        let first = Outbox(file: file) { _ in .accepted(Data()) }
        try await first.enqueue(OutboxItem(
            id: "d1", lane: "a", method: "DELETE", path: "x", body: Data(), createdAt: Date()
        ))
        #expect(await Outbox(file: file) { _ in .accepted(Data()) }.snapshot.first?.method == "DELETE")
    }

    /// Before the first unlock the file can't be read. It says nothing about what the file holds, so nothing is written
    /// over it, and an item made meanwhile joins what it holds once it opens.
    @Test func aSealedFileIsNotWrittenOverAndJoinsTheItemsMadeMeanwhile() async throws {
        let file = tempFile()
        let earlier = Outbox(file: file) { _ in .accepted(Data()) }
        try await earlier.enqueue(item("old"))
        let onDisk = try Data(contentsOf: file)

        let sealed = Sealed()
        let script = Script([.retry("down"), .retry("down")])
        let outbox = Outbox(file: file, backoff: noWaiting, read: { url in
            if sealed.isSealed {
                throw CocoaError(.fileReadNoPermission)
            }
            return try Data(contentsOf: url)
        }, attempt: { await script.next($0) })
        #expect(await outbox.isEmpty)
        try await outbox.enqueue(item("new", lane: "b"))
        #expect(await outbox.snapshot.map(\.id) == ["new"])
        #expect(try Data(contentsOf: file) == onDisk)

        sealed.isSealed = false
        await outbox.start()
        await outbox.kick()
        #expect(await settled(outbox))
        #expect(await Set(script.sent).isSuperset(of: ["old", "new"]))
        #expect(await Outbox(file: file) { _ in .accepted(Data()) }.isEmpty)
    }

    /// Before the first unlock a new file can't be written either. A tap on the Lock Screen still goes.
    @Test func anItemThatCannotBeWrittenYetIsKeptInMemoryAndSaved() async throws {
        let file = tempFile()
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let outbox = Outbox(file: file) { _ in .retry("down", after: .seconds(600)) }
        try await outbox.enqueue(item("r1"))
        #expect(await outbox.snapshot.map(\.id) == ["r1"])
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        await outbox.start()
        #expect(await Outbox(file: file) { _ in .accepted(Data()) }.snapshot.map(\.id) == ["r1"])
    }

    @Test func afterADayItsOwnerIsTold() async throws {
        let told = Waits()
        var hooks = Outbox.Hooks()
        hooks.rejected = { _, _ in await told.add(.zero) }
        let outbox = Outbox(file: nil, hooks: hooks) { _ in .accepted(Data()) }
        try await outbox.enqueue(item("old", createdAt: Date(timeIntervalSinceNow: -Outbox.maxAge - 1)))
        await outbox.start()
        #expect(await until { await told.all.count == 1 })
    }

    /// The hook takes time, and a new item pumps the queue meanwhile.
    @Test func anItemTheServerHasAcceptedIsNotSentAgainWhileItsHookRuns() async throws {
        let hookGate = Gate(["hold"])
        var hooks = Outbox.Hooks()
        hooks.accepted = { _, _ in
            while await hookGate.isHeld("hold") {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let script = Script([])
        let outbox = Outbox(file: nil, backoff: noWaiting, hooks: hooks) { await script.next($0) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        #expect(await until { await script.sent == ["r1"] })
        try await Task.sleep(for: .milliseconds(10))
        try await outbox.enqueue(item("r2", lane: "b"))
        try await Task.sleep(for: .milliseconds(20))
        await hookGate.open()
        #expect(await settled(outbox))
        #expect(await script.sent.sorted() == ["r1", "r2"])
    }

    @Test func aBackgroundUploadsAnswerSettlesIt() async throws {
        let accepted = Waits()
        var hooks = Outbox.Hooks()
        hooks.accepted = { _, _ in await accepted.add(.zero) }
        let outbox = Outbox(file: nil, hooks: hooks) { _ in .retry("down", after: .seconds(600)) }
        await outbox.start()
        try await outbox.enqueue(item("r1"))
        await outbox.settle(id: "r1", .accepted(Data("{}".utf8)))
        #expect(await outbox.isEmpty)
        #expect(await accepted.all.count == 1)
    }
}

private final class Sealed: @unchecked Sendable {
    var isSealed = true
}

private actor Waits {
    var all: [Duration] = []
    func add(_ wait: Duration) { all.append(wait) }
}

struct OutboxVerdictTests {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: headers
        ) else {
            preconditionFailure("HTTPURLResponse refused status \(status)")
        }
        return response
    }

    private func verdict(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) -> OutboxVerdict {
        OutboxVerdict.of(
            data: Data(body.utf8), response: response(status, headers: headers),
            isValid: { (try? JSONSerialization.jsonObject(with: $0)) != nil }, rejection: { status, _ in "\(status)" }
        )
    }

    @Test func theServerHoldingItIsAccepted() {
        #expect(verdict(201) == .accepted(Data("{}".utf8)))
        #expect(verdict(200) == .accepted(Data("{}".utf8)))
    }

    @Test func aCaptivePortalsTwoHundredIsNotAccepted() {
        #expect(verdict(200, "<html>Sign in to Hotel WiFi</html>") == .retry("unreadable answer"))
    }

    @Test func serverTroubleIsRetriedAndRefusalIsNot() {
        for status in [408, 425, 429, 500, 502, 503, 504] {
            guard case .retry = verdict(status) else {
                Issue.record("\(status) should retry")
                continue
            }
        }
        for status in [400, 403, 404, 409, 413, 422] {
            #expect(verdict(status) == .rejected("\(status)"))
        }
    }

    @Test func retryAfterIsRead() {
        #expect(verdict(429, headers: ["Retry-After": "12"]) == .retry("server answered 429", after: .seconds(12)))
    }

    @Test func aDroppedConnectionIsRetried() {
        guard case .retry = OutboxVerdict.of(error: URLError(.networkConnectionLost)) else {
            Issue.record("a dropped connection should retry")
            return
        }
    }
}

struct OutboxBackoffTests {
    @Test func itGrowsToTheCapAndNeverPastIt() {
        var backoff = OutboxBackoff()
        backoff.random = { 1 }
        #expect(backoff.delay(afterAttempt: 1) == .seconds(1))
        #expect(backoff.delay(afterAttempt: 2) == .seconds(2))
        #expect(backoff.delay(afterAttempt: 4) == .seconds(8))
        #expect(backoff.delay(afterAttempt: 40) == .seconds(10))
    }

    @Test func fullJitterStaysAboveTheFloor() {
        var backoff = OutboxBackoff()
        backoff.random = { 0 }
        #expect(backoff.delay(afterAttempt: 9) == .milliseconds(250))
    }
}

struct PathStateTests {
    @Test func theFirstAnswerIsNotNews() {
        #expect(PathState().update(up: true, interfaces: ["en0"]).isNew == false)
    }

    @Test func comingBackAndMovingAreNewsAndGoingAwayIsNot() {
        let state = PathState()
        _ = state.update(up: true, interfaces: ["en0"])
        #expect(state.update(up: false, interfaces: []).isNew == false)
        #expect(state.update(up: true, interfaces: ["pdp_ip0"]).isNew == true)
        #expect(state.update(up: true, interfaces: ["pdp_ip0"]).isNew == false)
        #expect(state.update(up: true, interfaces: ["en0"]).isNew == true)
    }
}
