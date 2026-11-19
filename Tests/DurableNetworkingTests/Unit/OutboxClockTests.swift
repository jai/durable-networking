import Clocks
import DurableNetworking
import Foundation
import Testing

struct OutboxClockTests {
    @Test func aRetryWaitsForItsDueTimeOnTheGivenClock() async throws {
        let clock = TestClock()
        let origin = clock.now
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let accepted = AsyncStream<Void>.makeStream()
        let attempts = Attempts()
        var hooks = Outbox.Hooks()
        hooks.accepted = { _, _ in accepted.continuation.yield(()) }
        let outbox = Outbox(
            file: nil, hooks: hooks,
            now: {
                let elapsed = origin.duration(to: clock.now).components
                return date.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            },
            clock: clock, attempt: { _ in await attempts.next() }
        )
        await outbox.start()
        try await outbox.enqueue(OutboxItem(id: "a", lane: "a", path: "items", body: Data(), createdAt: date))
        await clock.advance()
        #expect(await attempts.count == 1)
        #expect(await outbox.snapshot.first?.nextAttemptAt == date.addingTimeInterval(10))
        await clock.advance(by: .seconds(9))
        #expect(await attempts.count == 1)
        await clock.advance(by: .seconds(1))
        for await _ in accepted.stream { break }
        #expect(await attempts.count == 2)
        #expect(await outbox.isEmpty)
        try await clock.checkSuspension()
    }
}

private actor Attempts {
    var count = 0
    func next() -> OutboxVerdict {
        count += 1
        return count == 1 ? .retry("try later", after: .seconds(10)) : .accepted(Data())
    }
}
