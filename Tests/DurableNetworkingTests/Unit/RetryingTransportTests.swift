import DurableNetworking
import Foundation
import Synchronization
import Testing

struct RetryingTransportTests {
    private let url = URL(string: "https://example.test/items")!

    private func retrying(_ stub: StubTransport, inForeground: Bool = true) -> RetryingTransport {
        RetryingTransport(inner: stub, isInForeground: { inForeground }, sleep: { _ in })
    }

    private func post(idempotencyKey: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    @Test func aReadDroppedByTheNetworkIsTriedAgainUntilItGetsThrough() async throws {
        let stub = StubTransport([.fail(.networkConnectionLost), .fail(.timedOut), .reply(status: 200, body: "{}")])
        let (_, response) = try await retrying(stub).send(URLRequest(url: url))
        #expect(response.statusCode == 200 && stub.requests.count == 3)
    }

    @Test func itGivesUpAfterThreeTries() async {
        let stub = StubTransport(
            [.fail(.timedOut), .fail(.timedOut), .fail(.timedOut), .reply(status: 200, body: "{}")]
        )
        await #expect(throws: URLError.self) { try await retrying(stub).send(URLRequest(url: url)) }
        #expect(stub.requests.count == 3)
    }

    @Test func aWriteRepeatsOnlyWithAnIdempotencyKey() async throws {
        let bare = StubTransport([.fail(.networkConnectionLost), .reply(status: 201, body: "{}")])
        await #expect(throws: URLError.self) { try await retrying(bare).send(post()) }
        #expect(bare.requests.count == 1)

        let keyed = StubTransport([.fail(.networkConnectionLost), .reply(status: 201, body: "{}")])
        let (_, response) = try await retrying(keyed).send(post(idempotencyKey: "ref-a"))
        #expect(response.statusCode == 201 && keyed.requests.count == 2)
    }

    @Test func aBackgroundWakeNeverRetries() async {
        let stub = StubTransport([.fail(.networkConnectionLost), .reply(status: 200, body: "{}")])
        await #expect(throws: URLError.self) {
            try await retrying(stub, inForeground: false).send(URLRequest(url: url))
        }
        #expect(stub.requests.count == 1)
    }

    @Test func anAnswerFromTheServerAndABadRequestAreNotNetworkDrops() async throws {
        let answered = StubTransport([.reply(status: 500, body: "{}"), .reply(status: 200, body: "{}")])
        let (_, response) = try await retrying(answered).send(URLRequest(url: url))
        #expect(response.statusCode == 500 && answered.requests.count == 1)

        let badURL = StubTransport([.fail(.badURL), .reply(status: 200, body: "{}")])
        await #expect(throws: URLError.self) { try await retrying(badURL).send(URLRequest(url: url)) }
        #expect(badURL.requests.count == 1)
    }

    @Test func aTryAgainIsRepeatedUnseenAfterItsWait() async throws {
        let tryAgain = StubTransport.Scripted.replyWith(
            status: 503, body: #"{"error":{"code":"try_again"}}"#, headers: ["Retry-After": "1"]
        )
        let read = StubTransport([tryAgain, .reply(status: 200, body: "{}")])
        let waits = WaitLog()
        let transport = RetryingTransport(inner: read, isInForeground: { true }, sleep: { waits.add($0) })
        let (_, response) = try await transport.send(URLRequest(url: url))
        #expect(response.statusCode == 200 && read.requests.count == 2 && waits.all == [.seconds(1)])

        let keyed = StubTransport([tryAgain, .reply(status: 201, body: "{}")])
        #expect(try await retrying(keyed).send(post(idempotencyKey: "ref-b")).1.statusCode == 201)

        let bare = StubTransport([tryAgain, .reply(status: 201, body: "{}")])
        #expect(try await retrying(bare).send(post()).1.statusCode == 503 && bare.requests.count == 1)
    }

    @Test func aLongOrMissingRetryAfterIsTheCallersToShow() async throws {
        for headers in [["Retry-After": "60"], [:], ["Retry-After": "soon"]] {
            let stub = StubTransport([
                .replyWith(status: 503, body: "{}", headers: headers), .reply(status: 200, body: "{}"),
            ])
            #expect(try await retrying(stub).send(URLRequest(url: url)).1.statusCode == 503)
            #expect(stub.requests.count == 1)
        }
    }
}

/// The waits a transport asked for, in order.
private final class WaitLog: Sendable {
    private let waits = Mutex<[Duration]>([])
    var all: [Duration] { waits.withLock { $0 } }
    func add(_ wait: Duration) { waits.withLock { $0.append(wait) } }
}

private final class StubTransport: HTTPTransport, Sendable {
    enum Scripted: Sendable {
        case reply(status: Int, body: String)
        case replyWith(status: Int, body: String, headers: [String: String])
        case fail(URLError.Code)
    }

    private struct State {
        var script: [Scripted]
        var requests: [URLRequest] = []
    }
    private let state: Mutex<State>
    init(_ script: [Scripted]) { state = Mutex(State(script: script)) }
    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state in
            state.requests.append(request)
            return state.script.isEmpty ? .fail(.notConnectedToInternet) : state.script.removeFirst()
        }
        switch reply {
        case let .fail(code): throw URLError(code)
        case let .reply(status, body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .replyWith(status, body, headers):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
}
