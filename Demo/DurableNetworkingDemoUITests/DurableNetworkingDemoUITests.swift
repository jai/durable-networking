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
        let attempts = app.staticTexts.matching(identifier: "attempt").allElementsBoundByIndex.map(Self.text)
        let results = app.staticTexts.matching(identifier: "result").allElementsBoundByIndex.map(Self.text)
        var ends: [String] = []
        for identifier in ["server.stored", "server.deliveries", "outbox.count", "item.state"]
            where element(identifier).exists {
            ends.append(label(identifier))
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

    // MARK: - Airplane Wi-Fi

    /// Six reads over the emulated 600 ms link (geo_link.py): direct on new connections, then boosted through the
    /// satmux relay over warm carriers, then direct again once the boost is off.
    func testAirplaneBoostLoadsAScreenFaster() throws {
        scrollTo("airplane.load")
        tap("airplane.load")
        let direct = try waitForLoad(1, prefix: "direct")
        XCTAssertTrue(direct.line.contains("6/6 loaded · 0 via relay"), direct.line)

        tap("airplane.boost")
        waitForLabel("airplane.status", prefix: "Boost: on · 12 carriers", timeout: 20)
        tap("airplane.load")
        let boosted = try waitForLoad(2, prefix: "boost")
        XCTAssertTrue(boosted.line.contains("6/6 loaded · 6 via relay"), boosted.line)
        print("DEMO-E2E airplane: direct \(direct.seconds) s, boosted \(boosted.seconds) s")
        XCTAssertLessThan(boosted.seconds, direct.seconds * 0.6, "boosted \(boosted.line); direct \(direct.line)")

        tap("airplane.boost")
        waitForLabel("airplane.status", "Boost: off")
        tap("airplane.load")
        let after = try waitForLoad(3, prefix: "direct")
        XCTAssertTrue(after.line.contains("0 via relay"), after.line)
        record()
    }

    /// Auto over the satellite link: the carriers measure its 600 ms round trip and the reads go through the relay. Then
    /// the ground link: the carriers reconnect, measure next to nothing, and the reads go direct.
    func testAirplaneAutoBoostsOnlyOverTheSatellite() throws {
        scrollTo("airplane.auto")
        tap("airplane.auto")
        waitForLabel("airplane.status", prefix: "Boost: auto, relaying · 12 carriers", timeout: 20)
        tap("airplane.load")
        let satellite = try waitForLoad(1, prefix: "auto")
        XCTAssertTrue(satellite.line.contains("6/6 loaded · 6 via relay"), satellite.line)

        tap("airplane.link")
        waitForLabel("airplane.linkStatus", "Link: ground")
        waitForLabel("airplane.status", prefix: "Boost: auto, direct · 12 carriers", timeout: 20)
        tap("airplane.load")
        let ground = try waitForLoad(2, prefix: "auto")
        XCTAssertTrue(ground.line.contains("6/6 loaded · 0 via relay"), ground.line)
        print("DEMO-E2E airplane auto: satellite \(satellite.seconds) s via relay, ground \(ground.seconds) s")
        record()
    }

    /// The `count`th load's line, once it shows, and its seconds.
    private func waitForLoad(_ count: Int, prefix: String) throws -> (line: String, seconds: Double) {
        let rows = app.staticTexts.matching(identifier: "airplane.result")
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 30), .completed, "load \(count) finished")
        let line = Self.text(rows.firstMatch) // Newest first.
        XCTAssertTrue(line.hasPrefix(prefix), line)
        let seconds = try XCTUnwrap(Double(line.components(separatedBy: " ")[1]), line)
        return (line, seconds)
    }

    /// Scrolls down until `identifier` is on screen: the grids are lazy, and make no button below the fold.
    private func scrollTo(_ identifier: String) {
        let target = app.buttons[identifier]
        for _ in 0..<10 where !(target.exists && target.isHittable) {
            scrollDown()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(identifier) exists")
    }

    /// iPhone swipes; the Mac has no swipe, so it scrolls the window's scroll view as a mouse wheel would.
    private func scrollDown() {
        #if os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        #else
        app.swipeUp()
        #endif
    }

    private func scrollUp() {
        #if os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 400)
        #else
        app.swipeDown()
        #endif
    }

    // MARK: - Helpers

    private static func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        for key in ["DEMO_SERVER_URL", "DEMO_AIRPLANE_ORIGIN"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
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
            scrollUp()
        }
        button.tap()
    }

    private func label(_ identifier: String) -> String {
        Self.text(element(identifier))
    }

    /// What a text shows. iPhone has it as the element's label; the Mac as its value, with an empty label.
    private static func text(_ element: XCUIElement) -> String {
        let label = element.label
        return label.isEmpty ? element.value as? String ?? "" : label
    }

    private func waitForLabel(
        _ identifier: String, _ text: String? = nil, prefix: String? = nil, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = text.map { NSPredicate(format: "label == %@ OR value == %@", $0, $0) }
            ?? NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix ?? "", prefix ?? "")
        let found = XCTNSPredicateExpectation(predicate: predicate, object: element(identifier))
        let result = XCTWaiter.wait(for: [found], timeout: timeout)
        XCTAssertEqual(
            result, .completed, "\(identifier) became \(text ?? prefix ?? ""); it is \(label(identifier))",
            file: file, line: line
        )
    }

    private func attempts(containing text: String) -> [String] {
        app.staticTexts.matching(identifier: "attempt").allElementsBoundByIndex.map(Self.text)
            .filter { $0.contains(text) }
    }

    private func waitForAttempt(
        containing text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) {
        let row = app.staticTexts.matching(Self.row("attempt", containing: text)).firstMatch
        let all = app.staticTexts.matching(identifier: "attempt").allElementsBoundByIndex.map(Self.text)
        XCTAssertTrue(
            row.waitForExistence(timeout: timeout), "an attempt shows \(text); attempts: \(all)", file: file, line: line
        )
    }

    private func waitForResult(
        containing text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) {
        let row = app.staticTexts.matching(Self.row("result", containing: text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "a result shows \(text)", file: file, line: line)
    }

    /// A row `identifier` whose text contains `text`, as label (iPhone) or value (Mac).
    private static func row(_ identifier: String, containing text: String) -> NSPredicate {
        NSPredicate(format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)", identifier, text, text)
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
