import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Channel-timeline model", .timeLimit(.minutes(1)))
struct ChannelTimelineModelTests {
    @Test("streams an ingested batch into rows, oldest-first, without manual refresh")
    func streamsBatch() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
            try author.message("two", in: "room-1", at: 1_001),
            try author.message("three", in: "room-1", at: 1_002),
        ], phase: .backfill)

        await waitUntil { model.rows.count == 3 }
        // Ascending, so the bottom-anchored view renders newest last.
        #expect(model.rows.map(\.content) == ["one", "two", "three"])
        #expect(model.rows.allSatisfy { $0.delivery == .sent })
    }

    @Test("mark-on-view marks the channel read up to the newest message, once per advance")
    func marksOnView() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let marker = RecordingReadStateMarker()

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), readStateMarking: marker
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
            try author.message("two", in: "room-1", at: 2_000),
        ], phase: .backfill)

        // Opening the channel marks it read up to the newest message, exactly once.
        await waitUntil { model.rows.count == 2 }
        await waitUntil { await marker.lastUpTo == 2_000 }
        #expect(await marker.upTos == [2_000])

        // A newer arrival re-marks; a re-read that adds nothing newer (here, the same
        // rows re-observed) never does, so the frontier only ever advances.
        _ = try await store.ingest(batch: [
            try author.message("three", in: "room-1", at: 3_000),
        ], phase: .live)
        await waitUntil { model.rows.count == 3 }
        await waitUntil { await marker.lastUpTo == 3_000 }
        #expect(await marker.upTos == [2_000, 3_000])
    }

    @Test("a frozen tail holds the read frontier at the newest message the reader can see")
    func markReadStopsAtTheFrozenBoundary() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let marker = RecordingReadStateMarker()

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), readStateMarking: marker
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)
        await waitUntil { await marker.lastUpTo == 1_000 }

        // The reader scrolls up, so what arrives now is held back. Read state is grow-only
        // and shared with every other device, so a frontier that moved past a message the
        // reader never saw is not recoverable: the pill would say "1 new message" while the
        // sidebar row for the same channel un-bolded, and backing out would lose the
        // marker everywhere.
        model.isAtBottom = false
        _ = try await store.ingest(batch: [
            try author.message("two", in: "room-1", at: 2_000),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 1 }
        #expect(await marker.upTos == [1_000])

        // Asking for the held-back messages renders them, and only then does the frontier
        // advance — mark-on-view, where "view" means what was actually viewable.
        model.jumpToLatest()
        #expect(model.rows.count == 2)
        await waitUntil { await marker.lastUpTo == 2_000 }
        #expect(await marker.upTos == [1_000, 2_000])
    }

    @Test("a discarded own pending row leaves the timeline")
    func discardedRowIsPruned() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("logged", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.rows.map(\.content) == ["logged"] }

        // An own optimistic send: the head query unions pending outbox rows, so it renders.
        let mine = try await store.enqueue(
            content: "mine",
            in: "room-1",
            tags: [["h", "room-1"]],
            with: InMemorySigner(author.key)
        )
        await waitUntil { model.rows.map(\.content) == ["logged", "mine"] }

        // Discarding it drops the outbox row, so the head stops returning it. A merge by
        // id alone could only ever add, which left the row on screen until the channel was
        // reopened — and the frozen tail then counted a row that no longer exists.
        try await store.discard(mine.event.id)
        await waitUntil { model.rows.map(\.content) == ["logged"] }
    }

    /// The case the newest-row-only version of the prune could not see.
    ///
    /// A ghost that is *not* the newest loaded row has to be dropped too, and it is the
    /// realistic shape: an own send fails, the author leaves it queued, other people keep
    /// talking, and only then is it discarded. With the page's floor mistaken for its
    /// newest row, every such row compared as older than the floor and survived.
    @Test("a discarded own row is pruned even with newer messages above it")
    func discardedMiddleRowIsPruned() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("before", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.rows.map(\.content) == ["before"] }

        // Queued at 1_500, so it sorts *between* the two relay messages.
        let mine = try await store.enqueue(
            content: "mine",
            in: "room-1",
            tags: [["h", "room-1"]],
            with: InMemorySigner(author.key),
            createdAt: Date(timeIntervalSince1970: 1_500)
        )
        _ = try await store.ingest(batch: [
            try author.message("after", in: "room-1", at: 2_000),
        ], phase: .live)
        await waitUntil { model.rows.map(\.content) == ["before", "mine", "after"] }

        try await store.discard(mine.event.id)
        await waitUntil { model.rows.map(\.content) == ["before", "after"] }
    }

    @Test("page one is on screen on the first body pass, before any observation fires")
    func primesFirstPageOnFirstBodyPass() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let first = try author.message("one", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [
            first,
            try author.message("two", in: "room-1", at: 1_001),
            try author.event(.reaction, "👍", tags: [["e", first.id]], at: 1_002),
        ], phase: .backfill)

        // No `run()`: nothing has observed anything. `primeIfNeeded()` is what the view's
        // `body` calls, and a `body` runs before layout — so everything below is what the
        // first layout of the scroll view sees, which is the whole point: a bottom anchor
        // resolved against an empty stack is the "opens in the wrong place and then jumps"
        // defect. Construction itself stays free, because SwiftUI initialises and discards
        // this view's struct on every commit while the channel is open.
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        #expect(model.rows.isEmpty)
        #expect(!model.hasLoaded)

        model.primeIfNeeded()

        #expect(model.hasLoaded)
        #expect(model.rows.map(\.content) == ["one", "two"])
        // A short channel knows it is short at init, so no top spinner is reserved and
        // no first-frame `loadOlder()` fires into an empty cursor.
        #expect(!model.hasMoreOlder)
        // Grouped, so the day separator is part of that same first layout.
        #expect(shape(model.items) == ["day", "one", "two"])
        // And chips too: a reaction row appearing a frame later is another content
        // height change at the bottom.
        #expect(model.reactions(for: first.id).first?.emoji == "👍")

        // Idempotent: the view's `body` runs many times, and only the first may read.
        model.primeIfNeeded()
        #expect(model.rows.map(\.content) == ["one", "two"])
    }

    @Test("a full first page leaves pagination open as soon as it is primed")
    func fullFirstPageOffersOlder() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        var batch: [NostrEvent] = []
        for index in 0 ..< 12 {
            batch.append(try author.message("m\(index)", in: "room-1", at: 1_000 + Int64(index)))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 10
        )
        model.primeIfNeeded()
        #expect(model.rows.count == 10)
        #expect(model.hasMoreOlder)
    }

    @Test("grouped items are recomputed when rows change, one separator per local day")
    func regroupsOnRowsChange() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        // Two days apart, so the boundary holds in any device time zone.
        let twoDays: Int64 = 2 * 86_400
        _ = try await store.ingest(batch: [
            try author.message("monday", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        model.primeIfNeeded()
        #expect(shape(model.items) == ["day", "monday"])

        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("wednesday", in: "room-1", at: 1_000 + twoDays),
        ], phase: .live)

        await waitUntil { model.rows.count == 2 }
        #expect(shape(model.items) == ["day", "monday", "day", "wednesday"])
    }

    @Test("every change to what a row renders is declared, and the two kinds are told apart")
    func contentRevisionCoversWhatIsRendered() async throws {
        // The scaffold restores the reader's place across the settling that follows one of
        // these bumps, and across nothing else — so a change that forgets to bump is a real
        // insertion that moves the reader, and this is the only place that would catch it.
        // Both halves matter: the item set, and the chips drawn inside a row, which change
        // its height without changing the set at all.
        //
        // *Which* of the two it bumps is load-bearing on its own. An insertion above a reader
        // has to be corrected for and a row growing in front of them must not be, so a chip
        // sent down `contentRevision` is the reported jump on reacting to an older message.
        // See ``ConversationReaderPlace/rowDidChangeInPlace()``.
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        let first = try author.message("one", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [first], phase: .backfill)
        await waitUntil { model.rows.count == 1 }
        let afterFirstRow = model.contentRevision
        #expect(afterFirstRow > 0)

        _ = try await store.ingest(
            batch: [try author.message("two", in: "room-1", at: 1_001)], phase: .live
        )
        await waitUntil { model.rows.count == 2 }
        let afterSecondRow = model.contentRevision
        #expect(afterSecondRow > afterFirstRow)
        let rowsBeforeTheChip = model.rowRevision

        _ = try await store.ingest(
            batch: [try author.event(.reaction, "👍", tags: [["e", first.id]], at: 1_002)], phase: .live
        )
        await waitUntil { !model.reactions(for: first.id).isEmpty }
        // Declared — and declared as the other kind. The chip lands on a row that was already
        // in the list, so nothing above it moved and the reader's offset is still their place.
        #expect(model.rowRevision > rowsBeforeTheChip)
        #expect(model.contentRevision == afterSecondRow)
    }

    @Test("a message in another channel does not appear")
    func scopedToChannel() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("here", in: "room-1", at: 1_000),
            try author.message("elsewhere", in: "room-2", at: 1_001),
        ], phase: .backfill)

        await waitUntil { model.rows.count == 1 }
        #expect(model.rows.map(\.content) == ["here"])
    }

}
