import DurableNetworking
import Foundation
import Testing

struct Note: Codable, Equatable, Sendable { var text: String }
private let earlier = Date(timeIntervalSince1970: 1_000_000)
private let later = Date(timeIntervalSince1970: 2_000_000)

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
