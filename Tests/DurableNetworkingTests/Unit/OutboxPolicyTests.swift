@testable import DurableNetworking
import Foundation
import Testing

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
