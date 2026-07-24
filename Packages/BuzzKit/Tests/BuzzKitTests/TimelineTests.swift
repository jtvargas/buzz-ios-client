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

    // MARK: - Threading

    @Test("keeps replies out of the channel and returns them in their thread")
    func resolvesReplies() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let root = try fixture.message("root", at: 1000)
        let reply = try fixture.event(
            .channelMessage,
            "reply",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
            at: 1001
        )

        _ = try await store.ingest(batch: [root, reply], phase: .backfill)

        let channel = try store.timeline(channel: "room-1")
        #expect(channel.map(\.content) == ["root"])
        #expect(!channel[0].isReply)

        let thread = try store.thread(root: root.id)
        #expect(thread.map(\.content) == ["root", "reply"])
        #expect(thread[1].parentID == root.id)
        #expect(thread[1].rootID == root.id)
    }

    @Test("lets a broadcast reply through to the channel as well as its thread")
    func broadcastReplyInBoth() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let root = try fixture.message("root", at: 1000)
        let echoed = try fixture.event(
            .channelMessage,
            "echoed",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"], ["broadcast", "1"]],
            at: 1001
        )

        _ = try await store.ingest(batch: [root, echoed], phase: .backfill)

        #expect(try store.timeline(channel: "room-1").map(\.content) == ["echoed", "root"])
        #expect(try store.thread(root: root.id).map(\.content) == ["root", "echoed"])
    }

    @Test("tallies non-deleted replies with the time of the last one")
    func replyTallies() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let root = try fixture.message("root", at: 1000)
        let reply1 = try fixture.event(
            .channelMessage, "one", tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1001
        )
        let reply2 = try fixture.event(
            .channelMessage, "two", tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1002
        )

        _ = try await store.ingest(batch: [
            root, reply1, reply2,
            // Author removes their own second reply.
            fixture.event(.deletion, "", tags: [["e", reply2.id]], at: 1003),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first { $0.id == root.id })
        #expect(row.hasThread)
        #expect(row.replyCount == 1)
        #expect(row.lastReplyAt == 1001)
    }

    // MARK: - Outbox union

    @Test("a queued message appears in the timeline immediately, marked pending")
    func pendingAppears() async throws {
        // The point of optimistic send: the message is on screen before the relay
        // has heard of it.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("optimistic", at: 1000)

        try await store.enqueueForTest(event, channel: "room-1")

        let rows = try store.timeline(channel: "room-1")
        #expect(rows.map(\.content) == ["optimistic"])
        #expect(rows[0].id == event.id)
        #expect(rows[0].delivery == .pending)
    }

    @Test("a queued message sorts by time among sent ones")
    func pendingSortsInPlace() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [
            fixture.message("older", at: 1000),
            fixture.message("newer", at: 3000),
        ], phase: .backfill)
        try await store.enqueueForTest(fixture.message("mine", at: 2000), channel: "room-1")

        // Unioning in SQL rather than keeping a separate pending list is what makes
        // this work without the two views disagreeing about order.
        #expect(try store.timeline(channel: "room-1").map(\.content) == ["newer", "mine", "older"])
    }

    @Test("a rejected send stays visible with its reason and original text")
    func failedStaysVisible() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("rejected", at: 1000)

        try await store.enqueueForTest(
            event, channel: "room-1", state: "failed", lastError: "restricted: not a member"
        )

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.delivery == .failed("restricted: not a member"))
        // Losing the text the user typed would be the worst possible outcome.
        #expect(row.content == "rejected")
    }
}
