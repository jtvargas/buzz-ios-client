@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("Channel timeline", .timeLimit(.minutes(1)))
struct TimelineTests {
    // MARK: - Shape

    @Test("returns messages newest first")
    func newestFirst() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [
            fixture.message("first", at: 1000),
            fixture.message("second", at: 2000),
            fixture.message("third", at: 3000),
        ], phase: .backfill)

        #expect(try store.timeline(channel: "room-1").map(\.content) == ["third", "second", "first"])
    }

    @Test("scopes to one channel")
    func scopesToChannel() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [
            fixture.message("in room 1", in: "room-1", at: 1000),
            fixture.message("in room 2", in: "room-2", at: 2000),
        ], phase: .backfill)

        #expect(try store.timeline(channel: "room-1").map(\.content) == ["in room 1"])
        #expect(try store.timeline(channel: "room-2").map(\.content) == ["in room 2"])
    }

    @Test("excludes non-message kinds")
    func excludesOtherKinds() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("real message", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            fixture.event(.reaction, "🐝", tags: [["h", "room-1"], ["e", message.id]], at: 1001),
            fixture.event(.metadata, #"{"name":"x"}"#, tags: [["h", "room-1"]], at: 1002),
        ], phase: .backfill)

        #expect(try store.timeline(channel: "room-1").map(\.content) == ["real message"])
    }

    // MARK: - Pagination

    @Test("paginates without skipping or repeating")
    func paginates() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let events = try (0 ..< 25).map { try fixture.message("m\($0)", at: 1000 + Int64($0)) }
        _ = try await store.ingest(batch: events, phase: .backfill)

        var seen: [String] = []
        var cursor: TimelineCursor?
        while true {
            let page = try store.timeline(channel: "room-1", before: cursor, limit: 10)
            guard let last = page.last else { break }
            seen.append(contentsOf: page.map(\.content))
            cursor = TimelineCursor(row: last)
        }

        #expect(seen.count == 25)
        #expect(Set(seen).count == 25, "no message may appear on two pages")
        #expect(seen.first == "m24")
        #expect(seen.last == "m0")
    }

    @Test("paginates correctly through same-second events")
    func paginatesSameSecond() async throws {
        // The reason the cursor is (created_at, id) and not created_at alone:
        // relays routinely deliver many events sharing a timestamp, and a
        // timestamp-only cursor either skips the rest of that second or serves them
        // again forever.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let events = try (0 ..< 20).map { try fixture.message("same-\($0)", at: 1000) }
        _ = try await store.ingest(batch: events, phase: .backfill)

        var seen: [String] = []
        var cursor: TimelineCursor?
        for _ in 0 ..< 10 {
            let page = try store.timeline(channel: "room-1", before: cursor, limit: 5)
            guard let last = page.last else { break }
            seen.append(contentsOf: page.map(\.id))
            cursor = TimelineCursor(row: last)
        }

        #expect(seen.count == 20)
        #expect(Set(seen).count == 20)
    }

    @Test("a cursor stays stable when older events arrive underneath it")
    func cursorStableUnderInsert() async throws {
        // Backfill inserts older history while the user is paging. The cursor is a
        // value, not an offset, so rows do not shift under it.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let newer = try (10 ..< 20).map { try fixture.message("m\($0)", at: 1000 + Int64($0)) }
        _ = try await store.ingest(batch: newer, phase: .backfill)

        let firstPage = try store.timeline(channel: "room-1", limit: 5)
        let cursor = TimelineCursor(row: try #require(firstPage.last))

        let older = try (0 ..< 10).map { try fixture.message("m\($0)", at: 1000 + Int64($0)) }
        _ = try await store.ingest(batch: older, phase: .backfill)

        let secondPage = try store.timeline(channel: "room-1", before: cursor, limit: 5)
        #expect(Set(firstPage.map(\.id)).isDisjoint(with: secondPage.map(\.id)))
        #expect(secondPage.map(\.content) == ["m14", "m13", "m12", "m11", "m10"])
    }

    /// The page is a union of three branches — messages, relay notices, pending sends —
    /// and each one carries its own `ORDER BY … LIMIT :limit` so it can stop early
    /// instead of being scanned whole (see ``fetchTimeline``). That is only sound while
    /// a row in the global newest `limit` is also in the newest `limit` of its own
    /// branch, so the condition worth pinning is the one where a single branch holds
    /// **more than a page of its own**: twelve messages against a page of five. If the
    /// per-branch bound were wrong, the message branch would fill the page by itself and
    /// the notice and the pending send — both newer than the fifth message — would
    /// silently vanish rather than error.
    @Test("a page draws from every branch even when one alone could fill it")
    func pageDrawsFromEveryBranch() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let signer = try InMemorySigner()
        let someoneElse = try PrivateKey().publicKey.hex

        var batch = try (1 ... 12).map { try fixture.message("m\($0)", at: Int64($0) * 1000) }
        // One notice inside the newest five, and one far below them: the second proves
        // the branch is bounded by the page rather than merely present in it.
        let joined = #"{"type":"member_joined","actor":"\#(fixture.pubkey)","target":"\#(someoneElse)"}"#
        batch.append(try fixture.event(.systemMessage, joined, tags: [["h", "room-1"]], at: 10_500))
        batch.append(try fixture.event(.systemMessage, joined, tags: [["h", "room-1"]], at: 500))
        _ = try await store.ingest(batch: batch, phase: .backfill)

        // A pending send between the newest two messages, so the outbox branch has to
        // sort into the middle of the page rather than onto either end of it.
        try await store.enqueue(
            content: "pending",
            in: "room-1",
            with: signer,
            createdAt: Date(timeIntervalSince1970: 11_500)
        )

        let page = try store.timeline(channel: "room-1", limit: 5)

        #expect(page.map(\.createdAt) == [12_000, 11_500, 11_000, 10_500, 10_000])
        #expect(page.map(\.isNotice) == [false, false, false, true, false])
        #expect(page[1].content == "pending")
    }

    /// The same condition as ``pageDrawsFromEveryBranch``, pinned on all three branches
    /// rather than on the one that happened to be over-full.
    ///
    /// That test gives the notice branch two rows and the outbox branch one against a
    /// page of five. Both are under the bound, so `ORDER BY … ASC LIMIT 5` and
    /// `ORDER BY … DESC LIMIT 5` return the *same* rows from them: only the message
    /// branch is over-full, so only the message branch is pinned. Mutating one branch's
    /// `ORDER BY` or `LIMIT` at a time, that fixture notices 2 of 9 mutations and this
    /// one notices 9 of 9 — measured, in `RESEARCH/TIMELINE_READ_COST.md` §6.
    ///
    /// # Why a burst paged to exhaustion, and not a wider version of the same page
    ///
    /// Event ids are hashes, so a test cannot choose them, and any assertion about *which*
    /// rows land in one page turns on how those hashes happen to sort. Paging the whole
    /// burst asks a question the ids cannot skew: every seeded row comes back exactly
    /// once, in four pages of six. A branch bounded on anything but the outer total order
    /// cuts its own page at the wrong rows, and the rows it dropped then fall below the
    /// cursor and are excluded for good — so the count comes up short rather than merely
    /// reordering.
    ///
    /// Putting all twenty-four rows in one second makes `id` the entire ordering, which
    /// is what makes a missing tiebreak visible at all. It is also what backfill does
    /// routinely; ``paginatesSameSecond`` pins that for the message branch alone.
    @Test("paging a same-second burst loses no row from any branch")
    func pinsEveryBranch() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        // Eight rows per branch against a page of six: every branch is over-full, so a
        // wrong bound on any one of them has to drop something.
        let burst: Int64 = 11_000
        var batch = try (1 ... 8).map { try fixture.message("m\($0)", at: burst) }
        for _ in 1 ... 8 {
            // A distinct target per notice, so no two notices hash to the same id.
            let target = try PrivateKey().publicKey.hex
            let joined = #"{"type":"member_joined","actor":"\#(fixture.pubkey)","target":"\#(target)"}"#
            batch.append(try fixture.event(.systemMessage, joined, tags: [["h", "room-1"]], at: burst))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        // Queued newest-id first, deliberately. `outbox_channel` is
        // `(channel_id, created_at)` with no `event_id`, so SQLite walks it backwards for
        // `created_at DESC` and a tie falls out in rowid order — seeding in ascending id
        // order would let a branch that dropped the `id` tiebreak return the right rows
        // for the wrong reason, and this test would pass on a query that was broken.
        let queued = try (1 ... 8).map { try fixture.message("p\($0)", at: burst) }
        for event in queued.sorted(by: { $0.id > $1.id }) {
            try await store.enqueueForTest(event, channel: "room-1")
        }

        var pages: [[TimelineRow]] = []
        var cursor: TimelineCursor?
        for _ in 0 ..< 10 {
            let page = try store.timeline(channel: "room-1", before: cursor, limit: 6)
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

    // MARK: - Content resolution

    @Test("shows the newest authorized edit in place of the original")
    func appliesEdits() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("teh typo", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            fixture.event(.messageEdit, "the typo", tags: [["e", message.id]], at: 1001),
            fixture.event(.messageEdit, "no typo", tags: [["e", message.id]], at: 1002),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "no typo")
        #expect(row.isEdited)
    }

    @Test("falls back to the original when no edit exists")
    func noEditFallback() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [fixture.message("as written", at: 1000)], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "as written")
        #expect(!row.isEdited)
    }

    @Test("flags a deleted message but keeps it in the timeline")
    func flagsDeleted() async throws {
        // The UI renders "message deleted" rather than a hole, so the row survives.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("delete me", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            fixture.event(.deletion, "", tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.isDeleted)
        #expect(row.content == "delete me")
    }

    @Test("joins author profile details, and falls back to a short key without one")
    func joinsProfile() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let known = try Fixture()
        let unknown = try Fixture()

        _ = try await store.ingest(batch: [
            known.event(.metadata, #"{"display_name":"Jed","picture":"https://x/y"}"#, at: 900),
            known.message("with profile", at: 1000),
            unknown.message("without profile", at: 1001),
        ], phase: .backfill)

        let rows = try store.timeline(channel: "room-1")
        let named = try #require(rows.first { $0.content == "with profile" })
        let anon = try #require(rows.first { $0.content == "without profile" })

        #expect(named.authorName == "Jed")
        #expect(named.displayName == "Jed")
        #expect(named.authorPicture == "https://x/y")
        #expect(anon.authorName == nil)
        #expect(anon.displayName == String(unknown.pubkey.prefix(8)))
    }
}
