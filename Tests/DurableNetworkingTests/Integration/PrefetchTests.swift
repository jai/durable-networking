@testable import DurableNetworking
import Foundation
import Testing

/// One canned answer for every request.
private struct Canned: HTTPTransport {
    var status = 200
    var body = #"{"text":"kept"}"#
    var error: (any Error)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error {
            throw error
        }
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let request = URLRequest(url: URL(string: "https://example.invalid/thread/t1")!)
private let key = InboxKey("thread/t1")
private let isNote: @Sendable (Data) throws -> Void = { _ = try JSONDecoder().decode(Note.self, from: $0) }

private func tempStore() -> ReadStore {
    ReadStore(directory: FileManager.default.temporaryDirectory.appending(path: "prefetch-\(UUID().uuidString)"))
}

struct PrefetchTests {
    @Test func keepsAnAnswerTheInboxOpensOn() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        try await Prefetcher(store: store, transport: Canned(), now: { savedAt })
            .load(key, request: request, validate: isNote)

        let inbox = await Inboxes(store: store).inbox(
            key, decode: { try JSONDecoder().decode(Note.self, from: $0) }, fetch: { throw URLError(.notConnectedToInternet) }
        )
        #expect(await inbox.state == .cached(Note(text: "kept"), savedAt: savedAt))
    }

    @Test func aPortalsPageReplacesNothing() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await Prefetcher(store: store, transport: Canned()).load(key, request: request, validate: isNote)

        await #expect(throws: ReadFailure.unreadable) {
            try await Prefetcher(store: store, transport: Canned(body: "<html>log in</html>"))
                .load(key, request: request, validate: isNote)
        }
        #expect(store.load(key)?.data == Data(#"{"text":"kept"}"#.utf8))
    }

    @Test func aRefusalKeepsNothing() async {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await #expect(throws: ReadFailure.refused(status: 404, reason: "not found")) {
            try await Prefetcher(store: store, transport: Canned(status: 404)).load(key, request: request, validate: isNote)
        }
        #expect(store.load(key) == nil)
    }

    @Test func noNetworkIsOffline() async {
        await #expect(throws: ReadFailure.offline) {
            try await Prefetcher(store: tempStore(), transport: Canned(error: URLError(.notConnectedToInternet)))
                .load(key, request: request, validate: isNote)
        }
    }
}
