import Foundation
@testable import DurableNetworking
import Testing

struct Note: Codable, Equatable, Sendable {
    var text: String
}

/// Answers from a script, one per read, counting the reads.
private actor Server {
    enum Answer {
        case body(String)
        case error(any Error)
        /// Holds the read until `open()`.
        case held(String)
    }

    var answers: [Answer]
    var reads = 0
    private var gate: CheckedContinuation<Void, Never>?

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func next() async throws -> Data {
        reads += 1
        let answer = answers.isEmpty ? .error(URLError(.notConnectedToInternet)) : answers.removeFirst()
        switch answer {
        case .body(let text):
            return Data(text.utf8)
        case .error(let error):
            throw error
        case .held(let text):
            await withCheckedContinuation { gate = $0 }
            return Data(text.utf8)
        }
    }

    func open() {
        gate?.resume()
        gate = nil
    }

    var isHolding: Bool { gate != nil }
}

private let decodeNote: @Sendable (Data) throws -> Note = { try JSONDecoder().decode(Note.self, from: $0) }
private let earlier = Date(timeIntervalSince1970: 1_000_000)
private let later = Date(timeIntervalSince1970: 2_000_000)

private func tempStore() -> ReadStore {
    ReadStore(directory: FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)"))
}

private func note(_ text: String) -> String {
    #"{"text":"\#(text)"}"#
}

@MainActor
private func inbox(_ server: Server, store: ReadStore? = nil, key: String = "notes", in inboxes: Inboxes? = nil)
    -> Inbox<Note> {
    (inboxes ?? Inboxes(store: store, now: { later })).inbox(InboxKey(key), decode: decodeNote) {
        try await server.next()
    }
}

@Suite("ReadState transitions")
struct ReadStateTests {
    typealias State = ReadState<Note>
    let first = Note(text: "a")
    let second = Note(text: "b")

    @Test func keptOpensWhatWasSaved() {
        #expect(State.empty.after(.kept(first, savedAt: earlier)) == .cached(first, savedAt: earlier))
    }

    @Test func keptAfterAFailedReadIsStaleWithThatFailure() {
        #expect(State.unreachable(.offline).after(.kept(first, savedAt: earlier))
            == .stale(first, savedAt: earlier, failure: .offline))
    }

    @Test func keptNeverReplacesAValue() {
        let states = [
            State.cached(first, savedAt: later), .fresh(first, readAt: later),
            .stale(first, savedAt: later, failure: .offline),
        ]
        for state in states {
            #expect(state.after(.kept(second, savedAt: earlier)) == state)
        }
    }

    @Test func anAnswerIsFreshFromAnyState() {
        let states: [State] = [
            .empty, .unreachable(.offline), .cached(first, savedAt: earlier), .fresh(first, readAt: earlier),
            .stale(first, savedAt: earlier, failure: .unreadable),
        ]
        for state in states {
            #expect(state.after(.answered(second, readAt: later)) == .fresh(second, readAt: later))
        }
    }

    @Test func aFailureWithNothingIsUnreachable() {
        #expect(State.empty.after(.failed(.offline)) == .unreachable(.offline))
        #expect(State.unreachable(.offline).after(.failed(.unreadable)) == .unreachable(.unreadable))
    }

    @Test func aFailureKeepsTheValueAndItsAge() {
        #expect(State.cached(first, savedAt: earlier).after(.failed(.offline))
            == .stale(first, savedAt: earlier, failure: .offline))
        #expect(State.fresh(first, readAt: earlier).after(.failed(.offline))
            == .stale(first, savedAt: earlier, failure: .offline))
        #expect(State.stale(first, savedAt: earlier, failure: .offline).after(.failed(.unreadable))
            == .stale(first, savedAt: earlier, failure: .unreadable))
    }

    @Test func forgottenIsEmpty() {
        #expect(State.fresh(first, readAt: earlier).after(.forgotten) == .empty)
    }

    @Test func failuresAreNamed() {
        #expect(ReadFailure.of(URLError(.notConnectedToInternet)) == .offline)
        #expect(ReadFailure.of(URLError(.timedOut)) == .offline)
        let refused = ReadFailure.refused(status: 503, reason: "busy")
        #expect(ReadFailure.of(refused) == refused)
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "html"))
        #expect(ReadFailure.of(decoding) == .unreadable)
    }
}

@Suite("Inbox")
@MainActor
struct InboxTests {
    @Test func opensOnWhatWasKeptThenRefreshes() async throws {
        let store = tempStore()
        try store.save(KeptAnswer(data: Data(note("kept").utf8), savedAt: earlier), for: InboxKey("notes"))
        let server = Server([.body(note("new"))])
        let read = inbox(server, store: store)
        #expect(read.state == .cached(Note(text: "kept"), savedAt: earlier))
        await read.refresh()
        #expect(read.state == .fresh(Note(text: "new"), readAt: later))
        #expect(store.load(InboxKey("notes")) == KeptAnswer(data: Data(note("new").utf8), savedAt: later))
    }

    @Test func offlineKeepsTheDataAndSaysWhy() async throws {
        let store = tempStore()
        try store.save(KeptAnswer(data: Data(note("kept").utf8), savedAt: earlier), for: InboxKey("notes"))
        let read = inbox(Server([.error(URLError(.notConnectedToInternet))]), store: store)
        await read.refresh()
        #expect(read.state == .stale(Note(text: "kept"), savedAt: earlier, failure: .offline))
        #expect(!read.isRefreshing)
    }

    @Test func aCaptivePortalsPageNeverReplacesGoodData() async throws {
        let store = tempStore()
        let kept = KeptAnswer(data: Data(note("kept").utf8), savedAt: earlier)
        try store.save(kept, for: InboxKey("notes"))
        let read = inbox(Server([.body("<html>Sign in to Hotel Wi-Fi</html>")]), store: store)
        await read.refresh()
        #expect(read.state == .stale(Note(text: "kept"), savedAt: earlier, failure: .unreadable))
        #expect(store.load(InboxKey("notes")) == kept)
    }

    @Test func nothingKeptAndNoNetworkIsUnreachable() async {
        let read = inbox(Server([.error(URLError(.networkConnectionLost))]), store: tempStore())
        #expect(read.state == .empty)
        await read.refresh()
        #expect(read.state == .unreachable(.offline))
    }

    @Test func theAppNamesItsOwnFailures() async {
        struct Refusal: Error {}
        let inboxes = Inboxes(store: nil, classify: { _ in .refused(status: 500, reason: "down") }, now: { later })
        let read = inbox(Server([.error(Refusal())]), in: inboxes)
        await read.refresh()
        #expect(read.state == .unreachable(.refused(status: 500, reason: "down")))
    }

    @Test func aSecondRefreshJoinsTheFirst() async {
        let server = Server([.held(note("one")), .body(note("two"))])
        let read = inbox(server)
        let first = Task { await read.refresh() }
        while await !server.isHolding {
            await Task.yield()
        }
        #expect(read.isRefreshing)
        let second = Task { await read.refresh() }
        await Task.yield()
        await server.open()
        await first.value
        await second.value
        #expect(await server.reads == 1)
        #expect(read.state == .fresh(Note(text: "one"), readAt: later))
    }

    @Test func aKeptAnswerThatNoLongerDecodesIsNone() throws {
        let store = tempStore()
        try store.save(KeptAnswer(data: Data(#"{"old":1}"#.utf8), savedAt: earlier), for: InboxKey("notes"))
        #expect(inbox(Server([]), store: store).state == .empty)
    }

    @Test func forgetDropsTheKeptCopy() async throws {
        let store = tempStore()
        let read = inbox(Server([.body(note("a"))]), store: store)
        await read.refresh()
        read.forget()
        #expect(read.state == .empty)
        #expect(store.load(InboxKey("notes")) == nil)
    }

    @Test func aWritesAnswerIsTheNewestCopy() throws {
        let store = tempStore()
        let read = inbox(Server([]), store: store)
        try read.take(Data(note("written").utf8))
        #expect(read.state == .fresh(Note(text: "written"), readAt: later))
        #expect(store.load(InboxKey("notes"))?.data == Data(note("written").utf8))
        #expect(throws: (any Error).self) { try read.take(Data("<html>".utf8)) }
        #expect(read.state == .fresh(Note(text: "written"), readAt: later))
    }

    @Test func oneInboxPerKeyWhileInUse() {
        let inboxes = Inboxes(store: nil)
        let server = Server([])
        let first = inbox(server, in: inboxes)
        #expect(inbox(server, in: inboxes) === first)
        #expect(inbox(server, key: "other", in: inboxes) !== first)
    }

    @Test func aReturningNetworkRetriesOnlyWhatFailed() async {
        let inboxes = Inboxes(store: nil, now: { later })
        let failed = Server([.error(URLError(.notConnectedToInternet)), .body(note("back"))])
        let fine = Server([.body(note("fine"))])
        let failedRead = inbox(failed, key: "failed", in: inboxes)
        let fineRead = inbox(fine, key: "fine", in: inboxes)
        await failedRead.refresh()
        await fineRead.refresh()
        await inboxes.retryFailed()
        #expect(failedRead.state == .fresh(Note(text: "back"), readAt: later))
        #expect(await failed.reads == 2)
        #expect(await fine.reads == 1)
    }

    @Test func keysAreDistinctFileNames() {
        #expect(InboxKey("list/lst_a").fileName != InboxKey("list_lst_a").fileName)
        #expect(!InboxKey("a/b").fileName.contains("/"))
    }
}
