import XCTest

/// End to end: the demo app against the demo server (Demo/server/demo_server.py, started before the tests), each
/// network condition from the app's buttons, checked by what reached the server and what the app shows. The server is
/// the judge: `Stored` counts distinct writes, `Deliveries` every POST that reached it.
@MainActor
final class DurableNetworkingDemoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = Self.launch(reset: true)
    }

    /// For the walk-through (docs/end-to-end-walkthrough.md): what the app showed at the end, and its screen. Each test
    /// calls it last; a failed test has its screen in the result bundle.
    private func record() {
        let attempts = app.staticTexts.matching(identifier: "attempt").allElementsBoundByIndex.map { $0.label }
        let results = app.staticTexts.matching(identifier: "result").allElementsBoundByIndex.map { $0.label }
        var ends: [String] = []
        for identifier in ["server.stored", "server.deliveries", "outbox.count", "item.state"] {
            if element(identifier).exists {
                ends.append(label(identifier))
            }
        }
        for line in attempts.reversed() + results.reversed() + ends where !line.isEmpty {
            print("DEMO-E2E \(name) \(line)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        Self.saveScreenshot(app, name: name)
    }

    // MARK: - Conditions

    func testOfflineThenBackOnline() {
        tap("condition.offline")
        tap("send")
        waitForLabel("outbox.count", "Outbox: 1")
        // At least one attempt failed offline and the write is waiting, saved.
        waitForAttempt(containing: "offline · offline")
        XCTAssertEqual(label("server.stored"), "Stored: 0")

        tap("backOnline")
        waitForLabel("outbox.count", "Outbox: 0")
        waitForLabel("server.stored", "Stored: 1")
        waitForLabel("server.deliveries", "Deliveries: 1")
        record()
    }

    func testSlowNetwork() {
        tap("condition.slow")
        let started = Date()
        tap("send")
        waitForLabel("server.stored", "Stored: 1", timeout: 15)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3, "a 3 s latency delays the write")
        waitForLabel("outbox.count", "Outbox: 0")
        waitForAttempt(containing: "latency 3 s · 200")
        record()
    }

    func testTimeoutThenRetry() {
        tap("condition.timeout")
        tap("send")
        waitForAttempt(containing: "timeout after 2 s · timed out")
        waitForLabel("server.stored", "Stored: 1", timeout: 20)
        waitForLabel("outbox.count", "Outbox: 0")
        waitForLabel("server.deliveries", "Deliveries: 1")
        record()
    }

    func testServerErrorsThenSuccess() {
        tap("condition.503")
        tap("send")
        waitForLabel("server.stored", "Stored: 1", timeout: 30)
        waitForLabel("outbox.count", "Outbox: 0")
        // The two 503s never reached the server: one delivery, after three attempts.
        XCTAssertEqual(label("server.deliveries"), "Deliveries: 1")
        XCTAssertEqual(attempts(containing: "· 503 ·").count, 2)
        waitForResult(containing: "accepted after 3 attempts")
        record()
    }

    func testTooManyRequestsWaitsForRetryAfter() {
        tap("condition.429")
        tap("send")
        waitForAttempt(containing: "429, Retry-After 3 s · 429")
        waitForAttempt(containing: "normal · 200", timeout: 15)
        // The transport measures the wait between the two attempts: at least the server's 3 s.
        let accepted = attempts(containing: "normal · 200").first ?? ""
        let waited = accepted.components(separatedBy: "waited ").last.flatMap { Double($0.prefix { $0 != " " }) }
        XCTAssertGreaterThanOrEqual(waited ?? 0, 3, "the next attempt waits for Retry-After: \(accepted)")
        waitForLabel("server.stored", "Stored: 1")
        waitForResult(containing: "accepted after 2 attempts")
        record()
    }

    func testDroppedConnectionMidUploadLandsOnce() {
        tap("condition.drop")
        tap("send")
        waitForAttempt(containing: "dropped after send · connection lost")
        waitForLabel("outbox.count", "Outbox: 0", timeout: 20)
        // The server got it twice and keeps one: the idempotency key.
        waitForLabel("server.deliveries", "Deliveries: 2")
        XCTAssertEqual(label("server.stored"), "Stored: 1")
        waitForResult(containing: "accepted after 2 attempts")
        record()
    }

    func testWritesInTheOutboxSurviveAKill() {
        tap("condition.offline")
        tap("send")
        tap("send")
        waitForLabel("outbox.count", "Outbox: 2")
        // Long enough offline for the backoff to grow, as in a lift: five failed attempts.
        waitForLabel("attempts.count", "Attempts: 5", timeout: 30)
        app.terminate()

        // A new process, with the network back: the outbox file still holds both, and they go.
        app = Self.launch(reset: false)
        let started = Date()
        waitForLabel("server.stored", "Stored: 2", timeout: 30)
        waitForLabel("outbox.count", "Outbox: 0")
        print("DEMO-E2E kill: both writes stored \(Date().timeIntervalSince(started)) s after relaunch")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a relaunch sends what the outbox holds at once")
        record()
    }

    func testPrefetchedItemOpensOffline() {
        tap("prefetch")
        waitForLabel("prefetch.result", prefix: "prefetched at")
        tap("condition.offline")
        tap("openItem")
        waitForLabel("item.title", "Item demo-1")
        waitForLabel("item.state", prefix: "stale, saved")
        XCTAssertTrue(label("item.state").hasSuffix("offline"), label("item.state"))
        record()
    }

    // MARK: - Helpers

    private static func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if let server = ProcessInfo.processInfo.environment["DEMO_SERVER_URL"] {
            app.launchEnvironment["DEMO_SERVER_URL"] = server
        }
        if reset {
            app.launchArguments.append("-reset")
        }
        app.launch()
        let stored = app.staticTexts["server.stored"]
        XCTAssertTrue(stored.waitForExistence(timeout: 15), "the demo app opened")
        return app
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) exists")
        if !button.isHittable {
            app.swipeDown()
        }
        button.tap()
    }

    private func label(_ identifier: String) -> String {
        element(identifier).label
    }

    private func waitForLabel(
        _ identifier: String, _ text: String? = nil, prefix: String? = nil, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = text.map { NSPredicate(format: "label == %@", $0) }
            ?? NSPredicate(format: "label BEGINSWITH %@", prefix ?? "")
        let found = XCTNSPredicateExpectation(predicate: predicate, object: element(identifier))
        let result = XCTWaiter.wait(for: [found], timeout: timeout)
        XCTAssertEqual(
            result, .completed, "\(identifier) became \(text ?? prefix ?? ""); it is \(label(identifier))",
            file: file, line: line
        )
    }

    private func attempts(containing text: String) -> [String] {
        app.staticTexts.matching(identifier: "attempt").allElementsBoundByIndex.map { $0.label }.filter { $0.contains(text) }
    }

    private func waitForAttempt(
        containing text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) {
        let row = app.staticTexts.matching(NSPredicate(format: "identifier == 'attempt' AND label CONTAINS %@", text))
            .firstMatch
        let all = app.staticTexts.matching(identifier: "attempt").allElementsBoundByIndex.map { $0.label }
        XCTAssertTrue(
            row.waitForExistence(timeout: timeout), "an attempt shows \(text); attempts: \(all)", file: file, line: line
        )
    }

    private func waitForResult(
        containing text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) {
        let row = app.staticTexts.matching(NSPredicate(format: "identifier == 'result' AND label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "a result shows \(text)", file: file, line: line)
    }

    /// For the walk-through: each test's last screen, into `TEST_RUNNER_DEMO_SCREENSHOTS` when it is set.
    private static func saveScreenshot(_ app: XCUIApplication, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["DEMO_SCREENSHOTS"] else {
            return
        }
        let file = URL(fileURLWithPath: folder).appending(path: "\(name.filter { $0.isLetter || $0.isNumber }).png")
        try? app.screenshot().pngRepresentation.write(to: file)
    }
}
