import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// Landing on a message the screen has never loaded: the window read, the gap it leaves,
/// and the forward pagination that closes it.
///
/// Every test here drives the model synchronously — `primeIfNeeded()` for the head page,
/// then the window — and deliberately does **not** start `run()`. The observation loop
/// re-merges the head on every commit, which is correct in production and would make the
/// loaded set a moving target for assertions about exactly which rows are held.
@MainActor
@Suite("Channel timeline window", .timeLimit(.minutes(1)))
struct ChannelTimelineWindowTests {
    /// `count` top-level messages one second apart, `m0` oldest.
    private func seed(_ count: Int, in channel: String = "room-1") throws -> [NostrEvent] {
        let author = try Fixture()
        return try (0 ..< count).map {
            try author.message("m\($0)", in: channel, at: 1_000 + Int64($0))
        }
    }

    private func model(_ store: BuzzEventStore, pageSize: Int) -> ChannelTimelineModel {
        ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender(), pageSize: pageSize)
    }

    // MARK: - The window

    @Test("reads history either side of the target and leaves a gap below it")
    func windowLoadsBothSides() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await store.ingest(batch: try seed(200), phase: .backfill)

        // A page of twenty, so the head holds m180…m199 and everything below it is
        // reachable only by paging — which is what makes m50 a genuine deep-history target.
        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(model.rows.map(\.content) == (180 ..< 200).map { "m\($0)" })

        #expect(model.loadWindow(around: try #require(idOf("m50", in: store)), above: 5, below: 8))

        // m45…m58 spliced in — five older, the target, eight newer — and the head untouched.
        let contents = model.rows.map(\.content)
        #expect(Array(contents.prefix(14)) == (45 ..< 59).map { "m\($0)" })
        #expect(Array(contents.suffix(20)) == (180 ..< 200).map { "m\($0)" })
        #expect(contents.count == 34, "the window and the head, with nothing in between")
        #expect(model.gapFrontier?.id == idOf("m58", in: store), "the seam follows the window's newest row")
    }

    @Test("no gap when the window runs into the head page")
    func windowMeetingHeadLeavesNoGap() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await store.ingest(batch: try seed(40), phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()

        // The head holds m20…m39. A window around m18 reaching eight rows forward covers
        // m19…m26, which overlaps rows the head already holds — so there is nothing between.
        #expect(model.loadWindow(around: try #require(idOf("m18", in: store)), above: 5, below: 8))
        #expect(model.gapFrontier == nil)
        #expect(model.rows.map(\.content) == (13 ..< 40).map { "m\($0)" })
    }

    // MARK: - Closing the gap

    /// The ordering claim, held to `pinsEveryBranchAscending`'s standard: repeated forward
    /// pages drain **exactly** the rows between the window and the head, each one once, and
    /// the seam clears at the boundary rather than a page early or late.
    ///
    /// A page that skipped rows leaves holes in the contiguity check; one that repeated them
    /// cannot, because `loaded` is keyed by id — so the count is what catches a short drain
    /// and the contiguity is what catches a mis-ordered one.
    @Test("the gap drains in order, exactly once, and closes at the head")
    func gapDrainsAndCloses() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await store.ingest(batch: try seed(200), phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(model.loadWindow(around: try #require(idOf("m50", in: store)), above: 5, below: 8))
        #expect(model.gapFrontier != nil)

        var passes = 0
        while model.gapFrontier != nil, passes < 20 {
            await model.closeGap()
            passes += 1
        }

        #expect(model.gapFrontier == nil, "the drain must terminate")
        #expect(passes == 7, "twenty a page from m58 to the head is seven pages, not a loop that stops early")
        // m45 through m199 with nothing missing and nothing doubled: the window's older
        // edge is still the oldest thing loaded, and the timeline is now contiguous to now.
        #expect(model.rows.map(\.content) == (45 ..< 200).map { "m\($0)" })
    }

    /// The seam is what makes the hole honest, so where it sits is part of the contract:
    /// directly after the window's newest row, and gone the moment the gap closes.
    @Test("the seam is rendered after the window's newest row, and only while there is a gap")
    func seamSitsAtTheFrontier() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await store.ingest(batch: try seed(200), phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(!model.items.contains { $0.isGap }, "a contiguous timeline has no seam")

        #expect(model.loadWindow(around: try #require(idOf("m50", in: store)), above: 5, below: 8))
        let seamIndex = try #require(model.items.firstIndex { $0.isGap })
        #expect(model.items[seamIndex - 1].message?.content == "m58", "the seam follows the newest window row")
        #expect(model.items.filter(\.isGap).count == 1)

        while model.gapFrontier != nil { await model.closeGap() }
        #expect(!model.items.contains { $0.isGap }, "closing the gap removes the seam")
    }

    @Test("closing an already-closed gap does nothing")
    func closeGapIsIdempotentWhenClosed() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await store.ingest(batch: try seed(40), phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(model.loadWindow(around: try #require(idOf("m18", in: store)), above: 5, below: 8))

        let before = model.rows.map(\.id)
        await model.closeGap()
        #expect(model.rows.map(\.id) == before)
    }

    // MARK: - What this surface cannot show

    @Test("refuses a message that is not in the store")
    func refusesUnknownMessage() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await store.ingest(batch: try seed(10), phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(model.loadWindow(around: String(repeating: "f", count: 64)) == false)
        #expect(model.gapFrontier == nil)
    }

    /// The store's by-id read is not channel-scoped, so without the window read's own
    /// membership check this would splice another conversation's message into this one.
    @Test("refuses a message belonging to another channel")
    func refusesForeignChannelMessage() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let elsewhere = try seed(5, in: "room-2")
        _ = try await store.ingest(batch: try seed(10) + elsewhere, phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(model.loadWindow(around: elsewhere[2].id) == false)
        #expect(!model.rows.contains { $0.id == elsewhere[2].id }, "nothing from room-2 may be spliced in")
        #expect(model.rows.count == 10)
    }

    /// A non-broadcast thread reply is in the store and is never a channel-timeline row
    /// (`Timeline.swift`'s message branch excludes it), so the window read cannot land on
    /// one — the caller routes it to its thread instead.
    @Test("refuses a thread reply, which this surface never renders")
    func refusesThreadReply() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        let reply = try author.event(
            .channelMessage,
            "in the thread",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
            at: 1_001
        )
        _ = try await store.ingest(batch: [root, reply], phase: .backfill)

        let model = model(store, pageSize: 20)
        model.primeIfNeeded()
        #expect(model.rows.map(\.content) == ["root"], "the reply is not a row here to begin with")
        #expect(model.loadWindow(around: reply.id) == false)
        #expect(model.gapFrontier == nil)
    }

    /// The id of a seeded message, read back through the same store the model reads.
    private func idOf(_ content: String, in store: BuzzEventStore) -> String? {
        try? store.timeline(channel: "room-1", limit: 500).first { $0.content == content }?.id
    }
}

private extension ConversationItem {
    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }
}
