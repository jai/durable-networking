import Clocks
import DurableNetworking
import Foundation
import Testing

struct DeadlineTests {
    @Test func returnsTheValueOfAFastOperationAndRethrowsItsError() async throws {
        let clock = TestClock()
        #expect(try await withDeadline(.seconds(5), clock: clock) { 42 } == 42)
        await #expect(throws: URLError.self) {
            try await withDeadline(.seconds(5), clock: clock) { throw URLError(.badURL) }
        }
        try await clock.checkSuspension()
    }

    @Test func throwsWhenTheOperationOutlivesTheDeadline() async throws {
        let clock = TestClock()
        let task = Task {
            try await withDeadline(.milliseconds(200), clock: clock) {
                try await clock.sleep(for: .seconds(2))
            }
        }
        await clock.advance(by: .milliseconds(200))
        await #expect(throws: DeadlineExceeded.self) { try await task.value }
        try await clock.checkSuspension()
    }

    @Test func firesEvenWhenTheOperationIgnoresCancellation() async throws {
        let clock = TestClock()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        let task = Task {
            try await withDeadline(.milliseconds(150), clock: clock) {
                await withCheckedContinuation { continuation in
                    started.continuation.yield(())
                    Task {
                        for await _ in release.stream { break }
                        continuation.resume()
                        finished.continuation.yield(())
                    }
                }
            }
        }
        for await _ in started.stream { break }
        await clock.advance(by: .milliseconds(150))
        await #expect(throws: DeadlineExceeded.self) { try await task.value }
        release.continuation.yield(())
        for await _ in finished.stream { break }
        try await clock.checkSuspension()
    }
}
