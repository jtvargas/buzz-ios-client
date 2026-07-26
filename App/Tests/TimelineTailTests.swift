import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The rendered-tail freeze: what a reader who has scrolled up is protected from, and
/// what releases it.
@MainActor
@Suite("Timeline tail freeze", .timeLimit(.minutes(1)))
struct TimelineTailTests {
    @Test("an arrival is held back while the reader is away from the bottom")
    func holdsArrivalsWhileScrolledUp() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
            try author.message("two", in: "room-1", at: 1_001),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded && model.rows.count == 2 }

        // The reader scrolls up. Nothing is held back yet — the freeze is a boundary,
        // not a filter.
        model.isAtBottom = false
        #expect(model.heldBackCount == 0)
        #expect(model.rows.count == 2)

        _ = try await store.ingest(batch: [
            try author.message("three", in: "room-1", at: 1_002),
        ], phase: .live)

        // The arrival is counted, not rendered: the content height does not change, so
        // nothing under the reader moves.
        await waitUntil { model.heldBackCount == 1 }
        #expect(model.rows.map(\.content) == ["one", "two"])
        #expect(shape(model.items) == ["day", "one", "two"])

        // A second arrival adds to the count and still renders nothing.
        _ = try await store.ingest(batch: [
            try author.message("four", in: "room-1", at: 1_003),
        ], phase: .live)
        await waitUntil { model.heldBackCount == 2 }
        #expect(model.rows.count == 2)

        // Asking for them releases the boundary in one step and asks the view to move.
        model.jumpToLatest()
        #expect(model.heldBackCount == 0)
        #expect(model.rows.map(\.content) == ["one", "two", "three", "four"])
        #expect(shape(model.items) == ["day", "one", "two", "three", "four"])
        #expect(model.isAtBottom)
        #expect(model.jumpToken == 1)
    }

    @Test("returning to the bottom by scrolling releases the freeze too")
    func scrollingBackReleases() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded }

        model.isAtBottom = false
        _ = try await store.ingest(batch: [
            try author.message("two", in: "room-1", at: 1_001),
        ], phase: .live)
        await waitUntil { model.heldBackCount == 1 }

        // The scaffold reports the newest row back in view; no token is needed because
        // the reader is already there.
        model.isAtBottom = true
        #expect(model.heldBackCount == 0)
        #expect(model.rows.map(\.content) == ["one", "two"])
        #expect(model.jumpToken == 0)
    }

    @Test("an own send releases the freeze and jumps, so it is never hidden behind it")
    func ownSendJumps() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let sender = try RecordingSender()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: sender)
        model.isAtBottom = false

        model.draft = "mine"
        model.send()

        #expect(model.isAtBottom)
        #expect(model.heldBackCount == 0)
        #expect(model.jumpToken == 1)
        await waitUntil { await sender.sent.count == 1 }
    }

    @Test("an empty conversation freezes nothing, so the first message still appears")
    func emptyConversationFreezesNothing() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded }

        // Scrolled "up" in an empty channel — the geometry can report this while the
        // content is shorter than the viewport. A boundary at "nothing" would hide
        // every message the channel ever receives.
        model.isAtBottom = false
        _ = try await store.ingest(batch: [
            try author.message("first", in: "room-1", at: 1_000),
        ], phase: .live)

        await waitUntil { model.rows.count == 1 }
        #expect(model.heldBackCount == 0)
    }

    @Test("the boundary is a (createdAt, id) position, not a bare timestamp")
    func boundaryBreaksTiesOnID() {
        var tail = TimelineTail()
        let held = makeRow(id: "bbb", at: 1_000)
        let boundary = makeRow(id: "aaa", at: 1_000)
        tail.freeze(at: boundary)

        // Both rows carry the same second — the relay hands out many events per
        // second, which is why the keyset cursor exists at all. A timestamp-only
        // boundary would let `bbb` through the boundary it was meant to stop.
        let split = tail.split([boundary, held])
        #expect(split.rendered.map(\.id) == ["aaa"])
        #expect(split.heldBack == 1)

        tail.release()
        #expect(tail.split([boundary, held]).heldBack == 0)
    }
}
