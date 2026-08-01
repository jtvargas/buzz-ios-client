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
        #expect(model.jump.unreadCount == 0)
        #expect(model.rows.count == 2)

        _ = try await store.ingest(batch: [
            try author.message("three", in: "room-1", at: 1_002),
        ], phase: .live)

        // The arrival is counted, not rendered: the content height does not change, so
        // nothing under the reader moves.
        await waitUntil { model.jump.unreadCount == 1 }
        #expect(model.rows.map(\.content) == ["one", "two"])
        #expect(shape(model.items) == ["day", "one", "two"])

        // A second arrival adds to the count and still renders nothing.
        _ = try await store.ingest(batch: [
            try author.message("four", in: "room-1", at: 1_003),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 2 }
        #expect(model.rows.count == 2)

        // Asking for them releases the boundary in one step and asks the view to move.
        model.jumpToLatest()
        #expect(model.jump.unreadCount == 0)
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
        await waitUntil { model.jump.unreadCount == 1 }

        // The scaffold reports the newest row back in view; no token is needed because
        // the reader is already there.
        model.isAtBottom = true
        #expect(model.jump.unreadCount == 0)
        #expect(model.rows.map(\.content) == ["one", "two"])
        #expect(model.jumpToken == 0)
    }

    @Test("an own send releases the freeze and jumps at the tap, not at the relay's answer")
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

        // Synchronously, with no suspension in between. `SyncEngine.enqueue` commits the
        // outbox row and then waits for the drain — a publish round trip for every queued
        // row — so a jump behind that `await` arrives whenever the relay does. The freeze
        // has to come off here for a second reason: the message is newer than the boundary,
        // so while the freeze stands it is not rendered and there is nothing to land on.
        #expect(model.isAtBottom)
        #expect(model.jumpToken == 1)
        #expect(model.jump.unreadCount == 0)
        await waitUntil { await sender.sent.count == 1 }
    }

    @Test("the jump is re-asked once the message the author wrote is really on screen")
    func ownSendLandsOnItsOwnRow() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let sender = try RecordingSender()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: sender)
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded }
        model.isAtBottom = false

        model.draft = "mine"
        model.send()
        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.events.first)

        // At the tap the message had not been signed, so the jump could only aim at the row
        // that was newest *then*. Until this row exists there is nothing better to ask for.
        await waitUntil { model.awaitingOwnSend == sent.id }
        #expect(model.jumpToken == 1)

        // It commits — the moment the outbox row lands on a device — and the jump is asked
        // again, now that the newest row is the message the author wrote.
        _ = try await store.ingest(batch: [sent], phase: .live)
        await waitUntil { model.rows.contains { $0.id == sent.id } }
        await waitUntil { model.jumpToken == 2 }
        #expect(model.awaitingOwnSend == nil)
        #expect(model.jumpTarget == .bottom)
    }

    @Test("the freeze holds an own send too, so an author back in history is not chased")
    func theFreezeHoldsAnOwnSend() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let sender = try RecordingSender()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: sender)
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded }
        model.isAtBottom = false

        model.draft = "mine"
        model.send()
        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.events.first)
        await waitUntil { model.awaitingOwnSend == sent.id }

        // They go back to reading history before it arrives — by taking hold of the list, which
        // is the only thing that produces this now. The freeze re-arms, and it holds their own
        // message like any other arrival, so nothing lands on it and nothing moves them out of
        // what they chose to look at.
        //
        // The scaffold used to report this from the flight itself as well, and could not tell
        // the two apart: a jump to the newest row begins several viewports away, so its first
        // reading says `awayFromBottom` and re-froze the tail under a trip whose whole purpose
        // was to reach it. It declines that while a jump is in flight now — see
        // ``ConversationReaderPlace/isLandingOnNewest`` — so what remains here is the reader's
        // own doing, which is what this case is about.
        model.isAtBottom = false
        _ = try await store.ingest(batch: [sent], phase: .live)
        await waitUntil { model.jump.unreadCount == 1 }
        #expect(!model.rows.contains { $0.id == sent.id })
        #expect(model.jumpToken == 1)
    }

    @Test("a jump's own animation cannot cancel the landing it is on the way to")
    func theFlightDoesNotCancelTheLanding() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let sender = try RecordingSender()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: sender)
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded }
        model.isAtBottom = false

        model.draft = "mine"
        model.send()
        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.events.first)
        await waitUntil { model.awaitingOwnSend == sent.id }

        // What the scaffold used to report while the jump was in flight. A reader parked in
        // history is still hundreds of points from the bottom on the first frame of an animated
        // scroll, so geometry wrote `false` and then `true` again as it landed — and the message
        // being waited for is not the author changing their mind. Measured on a simulator:
        // treating it as one left the second jump unasked and the author's own message under
        // the composer.
        //
        // The scaffold no longer produces this sequence — it declines to re-freeze while a jump
        // to the newest row is in flight — and this case stays anyway, because the model must
        // not depend on that. `isAtBottom` is written from geometry, and geometry is estimated:
        // the guard for landing on an own send is the freeze, never this flag.
        model.isAtBottom = false
        model.isAtBottom = true

        _ = try await store.ingest(batch: [sent], phase: .live)
        await waitUntil { model.jumpToken == 2 }
        #expect(model.awaitingOwnSend == nil)
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
        #expect(model.jump.unreadCount == 0)

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
        #expect(model.jump.unreadCount == 0)

        // The *second* arrival is where an unarmed boundary used to leak: `isAtBottom` is
        // already `false` and has no `false → false` transition left to freeze on, so
        // every message from here on moved the reader's place. The first content to
        // appear becomes the boundary instead.
        _ = try await store.ingest(batch: [
            try author.message("second", in: "room-1", at: 1_001),
        ], phase: .live)

        await waitUntil { model.jump.unreadCount == 1 }
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
        #expect(split.held.count == 1)

        // Boundary `bbb`, arrival `aaa`: the mirror, and the one that leaked. Compared as
        // a keyset position the arrival is *older* than the boundary, so it rendered —
        // inserted mid-content, moving the reader. Event ids are hashes, so which
        // direction a same-second arrival fell in was a coin flip.
        tail.freeze(at: higherID, among: [higherID])
        split = tail.split([lowerID, higherID])
        #expect(split.rendered.map(\.id) == ["bbb"])
        #expect(split.held.count == 1)

        // A row that was already on screen when the freeze was taken keeps rendering
        // whichever way its id sorts: the boundary asks about existence, not order.
        tail.freeze(at: higherID, among: [lowerID, higherID])
        #expect(tail.split([lowerID, higherID]).held.isEmpty)

        tail.release()
        #expect(tail.split([lowerID, higherID]).held.isEmpty)
    }
}
