@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The timeline's threading behaviour and its union with the pending outbox, split
/// from ``TimelineTests`` so neither suite's body grows unwieldy.
@Suite("Timeline threads and pending sends", .timeLimit(.minutes(1)))
struct TimelineThreadTests {
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

    @Test("a send parked on re-auth renders pending, never sent")
    func awaitingReauthRendersPending() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        try await store.enqueueForTest(
            fixture.message("parked", at: 1000),
            channel: "room-1",
            state: OutboxState.awaitingReauth.rawValue
        )

        // The relay has not accepted this event; showing it as sent would be a lie
        // the user only discovers when the message never arrives for anyone else.
        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.delivery == .pending)
    }
}
