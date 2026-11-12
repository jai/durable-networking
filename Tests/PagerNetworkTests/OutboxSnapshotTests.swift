import Foundation
@testable import PagerNetwork
import Testing

/// A reader that refreshes on every announcement holds several snapshots at once; the newer one is the higher revision.
@Suite("Outbox snapshots")
struct OutboxSnapshotTests {
    @Test func everyChangeMakesALaterSnapshotNewer() async throws {
        let outbox = Outbox(file: nil) { _ in .rejected("refused") }
        let empty = await outbox.state
        try await outbox.enqueue(OutboxItem(id: "a", lane: "a", path: "device/threads/replies", body: Data("{}".utf8), createdAt: Date()))
        let queued = await outbox.state
        await outbox.cancel(id: "a")
        let cancelled = await outbox.state
        #expect(queued.revision > empty.revision && cancelled.revision > queued.revision)
        #expect(queued.items.map(\.id) == ["a"] && cancelled.items.isEmpty)
    }
}
