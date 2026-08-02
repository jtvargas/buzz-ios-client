@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The ascending half of the channel page read — `timeline(channel:after:limit:)`.
///
/// Its own suite beside ``TimelineTests`` rather than more cases inside it, because these
/// are all one question: the read is the same keyset over the same three branches with its
/// comparison and its four `ORDER BY`s flipped together (``TimelineDirection``), and what
/// has to be earned is *ascending plus keyset paging* specifically.
///
/// Not the union under an ascending outer order — `fetchThread` has shipped that for a long
/// time — but that order combined with a cursor predicate and a per-branch `LIMIT`, which
/// `fetchThread` carries neither of and so says nothing about.
///
/// Each test names the descending case in ``TimelineTests`` it mirrors. Those stay put and
/// unmodified: that they still pass is the evidence the default path did not move.
@Suite("Channel timeline, read upward", .timeLimit(.minutes(1)))
struct TimelineDirectionTests {
    /// The mirror of ``TimelineTests/paginates()``.
    ///
    /// Also the only exercise of an ascending `nil` cursor, which reads from the start of
    /// the channel as `before: nil` reads from its head.
    @Test("paginates upward without skipping or repeating")
    func paginatesAscending() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let events = try (0 ..< 25).map { try fixture.message("m\($0)", at: 1000 + Int64($0)) }
        _ = try await store.ingest(batch: events, phase: .backfill)

        var seen: [String] = []
        var cursor: TimelineCursor?
        while true {
            let page = try store.timeline(channel: "room-1", after: cursor, limit: 10)
            guard let last = page.last else { break }
            seen.append(contentsOf: page.map(\.content))
            cursor = TimelineCursor(row: last)
        }

        #expect(seen.count == 25)
        #expect(Set(seen).count == 25, "no message may appear on two pages")
        #expect(seen.first == "m0")
        #expect(seen.last == "m24")
    }

    /// The mirror of ``TimelineTests/paginatesSameSecond()``, and the sharpest test of the flip: with
    /// every row inside one second the id tiebreak *is* the whole order, so a predicate
    /// left on `<` while the `ORDER BY` went `ASC` serves the same five rows for ever
    /// rather than returning them out of order.
    @Test("paginates upward correctly through same-second events")
    func paginatesSameSecondAscending() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let events = try (0 ..< 20).map { try fixture.message("same-\($0)", at: 1000) }
        _ = try await store.ingest(batch: events, phase: .backfill)

        var seen: [String] = []
        var cursor: TimelineCursor?
        for _ in 0 ..< 10 {
            let page = try store.timeline(channel: "room-1", after: cursor, limit: 5)
            guard let last = page.last else { break }
            seen.append(contentsOf: page.map(\.id))
            cursor = TimelineCursor(row: last)
        }

        #expect(seen.count == 20)
        #expect(Set(seen).count == 20)
    }

    /// The mirror of ``TimelineTests/pageDrawsFromEveryBranch()``, on the same fixture read from below
    /// rather than from the head — the cursor sits just under the band that holds one row
    /// of each kind, so a page of five has to interleave all three branches to fill.
    @Test("an upward page draws from every branch")
    func pageDrawsFromEveryBranchAscending() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let signer = try InMemorySigner()
        let someoneElse = try PrivateKey().publicKey.hex

        var batch = try (1 ... 12).map { try fixture.message("m\($0)", at: Int64($0) * 1000) }
        let joined = #"{"type":"member_joined","actor":"\#(fixture.pubkey)","target":"\#(someoneElse)"}"#
        batch.append(try fixture.event(.systemMessage, joined, tags: [["h", "room-1"]], at: 10_500))
        batch.append(try fixture.event(.systemMessage, joined, tags: [["h", "room-1"]], at: 500))
        _ = try await store.ingest(batch: batch, phase: .backfill)

        try await store.enqueue(
            content: "pending",
            in: "room-1",
            with: signer,
            createdAt: Date(timeIntervalSince1970: 11_500)
        )

        let page = try store.timeline(
            channel: "room-1",
            after: TimelineCursor(createdAt: 9_999, id: ""),
            limit: 5
        )

        #expect(page.map(\.createdAt) == [10_000, 10_500, 11_000, 11_500, 12_000])
        #expect(page.map(\.isNotice) == [false, true, false, false, false])
        #expect(page[3].content == "pending")
    }

    /// The mirror of ``TimelineTests/pinsEveryBranch()``, and the one that earns the parameterisation.
    ///
    /// The per-branch `ORDER BY … LIMIT` bound is sound only while every branch orders the
    /// same way as the outer query; `top-N(A ∪ B ∪ C) ⊆ top-N(A) ∪ top-N(B) ∪ top-N(C)` is
    /// agnostic to *which* total order that is, but not to their disagreeing. A branch left
    /// on `DESC` under an `ASC` outer does not error — it cuts its own page at the wrong
    /// rows, and those rows then fall below the cursor and are excluded for good, so the
    /// drained count comes up short rather than merely reordering.
    ///
    /// Twenty-four rows in one second across all three branches against a page of six, for
    /// the reasons the descending fixture records: every branch over-full so a wrong bound
    /// on any one has to drop something, and one shared second so `id` is the entire
    /// ordering and a missing tiebreak is visible at all.
    @Test("paging a same-second burst upward loses no row from any branch")
    func pinsEveryBranchAscending() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let burst: Int64 = 11_000
        var batch = try (1 ... 8).map { try fixture.message("m\($0)", at: burst) }
        for _ in 1 ... 8 {
            let target = try PrivateKey().publicKey.hex
            let joined = #"{"type":"member_joined","actor":"\#(fixture.pubkey)","target":"\#(target)"}"#
            batch.append(try fixture.event(.systemMessage, joined, tags: [["h", "room-1"]], at: burst))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        // Seeded newest-id first, as the descending fixture does and for the same reason:
        // `outbox_channel` is `(channel_id, created_at)` with no `event_id`, so a tie falls
        // out in rowid order and a branch that dropped the `id` tiebreak could return the
        // right rows for the wrong reason. Adversarial against the ascending walk too —
        // rowid order is now the reverse of the order this read wants.
        let queued = try (1 ... 8).map { try fixture.message("p\($0)", at: burst) }
        for event in queued.sorted(by: { $0.id > $1.id }) {
            try await store.enqueueForTest(event, channel: "room-1")
        }

        var pages: [[TimelineRow]] = []
        var cursor: TimelineCursor?
        for _ in 0 ..< 10 {
            let page = try store.timeline(channel: "room-1", after: cursor, limit: 6)
            guard let last = page.last else { break }
            pages.append(page)
            cursor = TimelineCursor(row: last)
        }

        let seen = pages.flatMap { $0.map(\.id) }
        let seeded = Set(batch.map(\.id)).union(queued.map(\.id))

        #expect(seeded.count == 24, "the fixture must hand every branch more rows than a page")
        #expect(pages.count == 4, "a branch that stops short of its bound needs more pages to drain")
        #expect(seen.count == 24, "no row may be served twice")
        #expect(Set(seen) == seeded, "a branch bounded on the wrong order drops rows the page owned")
    }

    /// Both directions are strict about the cursor's own row, and between them they cover
    /// the channel exactly once.
    ///
    /// This is the property a caller reading a window *around* a message depends on: ask
    /// `before:` for one half and `after:` for the other and nothing is served twice, so
    /// neither side has to deduplicate against the other. The row itself belongs to
    /// whichever read is given the inclusive cursor — here, neither.
    @Test("the two directions are strict and disjoint about the cursor's own row")
    func directionsAreStrictAndDisjoint() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let events = try (0 ..< 12).map { try fixture.message("m\($0)", at: 1000 + Int64($0)) }
        _ = try await store.ingest(batch: events, phase: .backfill)

        let all = try store.timeline(channel: "room-1", limit: 50)
        #expect(all.count == 12)
        let pivot = all[6]
        let cursor = TimelineCursor(row: pivot)

        let older = try store.timeline(channel: "room-1", before: cursor, limit: 50)
        let newer = try store.timeline(channel: "room-1", after: cursor, limit: 50)

        #expect(!older.contains { $0.id == pivot.id }, "`before:` must not return its own cursor")
        #expect(!newer.contains { $0.id == pivot.id }, "`after:` must not return its own cursor")
        #expect(Set(older.map(\.id)).isDisjoint(with: newer.map(\.id)))
        #expect(Set(older.map(\.id)).union(newer.map(\.id)).union([pivot.id]) == Set(all.map(\.id)))

        // `all` is newest first, so `all[6]` is m5; the two halves are m4…m0 read down
        // and m6…m11 read up, with m5 itself in neither.
        #expect(pivot.content == "m5")
        #expect(older.map(\.content) == ["m4", "m3", "m2", "m1", "m0"])
        #expect(newer.map(\.content) == ["m6", "m7", "m8", "m9", "m10", "m11"])
    }
}
