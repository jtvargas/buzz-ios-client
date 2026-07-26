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
        model.primeIfNeeded()
        model.isAtBottom = false

        model.draft = "mine"
        model.send()

        // The jump lands once the message is really queued rather than at the tap: an
        // over-ceiling send throws before anything is enqueued, and yanking a reader out
        // of history for a message that never left the device is worse than not moving.
        await waitUntil { await sender.sent.count == 1 }
        await waitUntil { model.isAtBottom }
        #expect(model.heldBackCount == 0)
        #expect(model.jumpToken == 1)
    }

    @Test("an own send from the bottom does not re-anchor the author")
    func ownSendAtBottomDoesNotJump() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let sender = try RecordingSender()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: sender)
        model.primeIfNeeded()
        #expect(model.isAtBottom)
        #expect(model.heldBackCount == 0)

        model.draft = "mine"
        model.send()
        await waitUntil { await sender.sent.count == 1 }
        // A real suspension after the send is queued, so the jump has had its chance.
        await parkBriefly()

        // The author is already looking at the place the message will appear. Bumping the
        // token there animates a scroll to where the view already is, which interrupts
        // whatever momentum they were carrying for no gain.
        #expect(model.jumpToken == 0)
        #expect(model.isAtBottom)
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

        // The *second* arrival is where an unarmed boundary used to leak: `isAtBottom` is
        // already `false` and has no `false → false` transition left to freeze on, so
        // every message from here on moved the reader's place. The first content to
        // appear becomes the boundary instead.
        _ = try await store.ingest(batch: [
            try author.message("second", in: "room-1", at: 1_001),
        ], phase: .live)

        await waitUntil { model.heldBackCount == 1 }
        #expect(model.rows.map(\.content) == ["first"])

        // And it is a boundary, not a filter: asking for it renders both.
        model.jumpToLatest()
        #expect(model.rows.map(\.content) == ["first", "second"])
    }

    @Test("the boundary is a second plus that second's membership, so no tie leaks through")
    func boundaryHoldsBackEverySameSecondArrival() {
        var tail = TimelineTail()
        let lowerID = makeRow(id: "aaa", at: 1_000)
        let higherID = makeRow(id: "bbb", at: 1_000)

        // Boundary `aaa`, arrival `bbb`: the direction a `(createdAt, id) >` cursor also
        // got right, because the arrival's id happened to sort above the boundary's.
        tail.freeze(at: lowerID, among: [lowerID])
        var split = tail.split([lowerID, higherID])
        #expect(split.rendered.map(\.id) == ["aaa"])
        #expect(split.heldBack == 1)

        // Boundary `bbb`, arrival `aaa`: the mirror, and the one that leaked. Compared as
        // a keyset position the arrival is *older* than the boundary, so it rendered —
        // inserted mid-content, moving the reader. Event ids are hashes, so which
        // direction a same-second arrival fell in was a coin flip.
        tail.freeze(at: higherID, among: [higherID])
        split = tail.split([lowerID, higherID])
        #expect(split.rendered.map(\.id) == ["bbb"])
        #expect(split.heldBack == 1)

        // A row that was already on screen when the freeze was taken keeps rendering
        // whichever way its id sorts: the boundary asks about existence, not order.
        tail.freeze(at: higherID, among: [lowerID, higherID])
        #expect(tail.split([lowerID, higherID]).heldBack == 0)

        tail.release()
        #expect(tail.split([lowerID, higherID]).heldBack == 0)
    }
}
