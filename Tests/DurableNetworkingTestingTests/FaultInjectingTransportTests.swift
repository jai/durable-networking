import DurableNetworking
@testable import DurableNetworkingTesting
import Foundation
import Synchronization
import Testing

/// The server: answers 200 and counts what reached it.
private final class Server: HTTPTransport, Sendable {
    let reached = Mutex(0)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        reached.withLock { $0 += 1 }
        // swiftlint:disable:next force_unwrapping
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func post() -> URLRequest {
    // swiftlint:disable:next force_unwrapping
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8787/writes")!)
    request.httpMethod = "POST"
    request.setValue("k-1", forHTTPHeaderField: "Idempotency-Key")
    return request
}

struct FaultInjectingTransportTests {
    @Test func queuedConditionsApplyOnceEachThenTheStandingOne() async throws {
        let server = Server()
        let faults = FaultInjectingTransport(inner: server, sleep: { _ in })
        faults.next(.status(503), .status(429, retryAfter: 2))

        let first = try await faults.send(post())
        let second = try await faults.send(post())
        let third = try await faults.send(post())

        #expect(first.1.statusCode == 503)
        #expect(second.1.statusCode == 429)
        #expect(second.1.value(forHTTPHeaderField: "Retry-After") == "2")
        #expect(third.1.statusCode == 200)
        #expect(server.reached.withLock { $0 } == 1)
        #expect(faults.records.map(\.status) == [503, 429, 200])
        #expect(faults.records.map(\.key) == ["k-1", "k-1", "k-1"])
        #expect(faults.records.first?.waited == nil)
        #expect(faults.records.dropFirst().allSatisfy { $0.waited != nil })
    }

    @Test func offlineAndTimeoutNeverReachTheServer() async {
        let server = Server()
        let faults = FaultInjectingTransport(inner: server, sleep: { _ in })
        faults.next(.offline, .timeout(after: .seconds(1)))

        await #expect(throws: URLError(.notConnectedToInternet)) { try await faults.send(post()) }
        await #expect(throws: URLError(.timedOut)) { try await faults.send(post()) }
        #expect(server.reached.withLock { $0 } == 0)
        #expect(faults.records.map(\.error) == ["offline", "timed out"])
    }

    @Test func aDropAfterSendReachesTheServerAndLosesTheAnswer() async {
        let server = Server()
        let faults = FaultInjectingTransport(inner: server, sleep: { _ in })
        faults.set(.droppedAfterSend)

        await #expect(throws: URLError(.networkConnectionLost)) { try await faults.send(post()) }
        #expect(server.reached.withLock { $0 } == 1)
        #expect(faults.records.first?.reachedServer == true)
        #expect(faults.records.first?.error == "connection lost")
    }

    @Test func latencyWaitsThenSends() async throws {
        let waited = Mutex<[Duration]>([])
        let faults = FaultInjectingTransport(inner: Server(), sleep: { wait in waited.withLock { $0.append(wait) } })
        faults.set(.latency(.seconds(3)))

        let answer = try await faults.send(post())

        #expect(answer.1.statusCode == 200)
        #expect(waited.withLock { $0 } == [.seconds(3)])
    }

    @Test func theOutboxSendsAgainUntilTheServerAcceptsAndTheServerHoldsOneCopy() async throws {
        let server = Server()
        let faults = FaultInjectingTransport(inner: server, sleep: { _ in })
        faults.next(.status(503), .droppedAfterSend)
        let accepted = Mutex(0)
        var hooks = Outbox.Hooks()
        hooks.accepted = { _, _ in accepted.withLock { $0 += 1 } }
        var backoff = OutboxBackoff()
        backoff.floor = .zero
        backoff.random = { 0 }
        let outbox = Outbox(file: nil, backoff: backoff, hooks: hooks, sleep: { _ in }) { item in
            var request = post()
            request.setValue(item.id, forHTTPHeaderField: "Idempotency-Key")
            do {
                let (data, response) = try await faults.send(request)
                return .of(data: data, response: response, isValid: { _ in true }, rejection: { code, _ in "\(code)" })
            } catch {
                return .of(error: error)
            }
        }
        await outbox.start()
        try await outbox.enqueue(OutboxItem(id: "w-1", lane: "w", path: "writes", body: Data(), createdAt: Date()))

        for _ in 0..<200 where await !outbox.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await outbox.isEmpty)
        #expect(accepted.withLock { $0 } == 1)
        #expect(faults.records.map(\.condition) == [.status(503), .droppedAfterSend, .normal])
        // The dropped attempt reached the server, and so did the last: the idempotency key makes them one write there.
        #expect(server.reached.withLock { $0 } == 2)
    }
}
