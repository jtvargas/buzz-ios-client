@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

/// Which rows reach the **Agents** chip.
///
/// Its own suite because the rule is not the obvious one and is worth finding by name: an
/// agent is identified by its *author*, not by the event kind. The first cut keyed on the
/// job-lifecycle kinds (43001-43006) the way the relay's own feed SQL does, and on JT's
/// live relay zero such events exist — every agent replies as an ordinary `kind:9` message.
/// The chip was empty and would have stayed empty.
@Suite("Activity feed agents", .timeLimit(.minutes(1)))
struct ActivityFeedAgentTests {
    // MARK: - Agents

    @Test("an ordinary message from an agent lands under Agents as well as Mentions")
    func agentAuthoredMessagesAreAgentActivity() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let bot = try Fixture()
        let person = try Fixture()

        // The shape that actually exists on JT's relay, and the one the first cut of this
        // feed got wrong: agents do not send job-lifecycle kinds, they send `kind:9`
        // messages that name you. Keyed on the author's `bot` role, not on the kind.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.members(
                relay, "room-1", people: [me, person.pubkey], bots: [bot.pubkey], at: 501
            ),
            try ActivityFixtures.message(bot, "build is green", in: "room-1", mentions: [me], at: 1000),
            try ActivityFixtures.message(person, "and a human reply", in: "room-1", mentions: [me], at: 2000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        let fromBot = try #require(feed.first { $0.latest.content == "build is green" })
        let fromPerson = try #require(feed.first { $0.latest.content == "and a human reply" })

        // Both axes at once. It reads as a Mention — that is what someone naming you *is*,
        // and mention outranks agentActivity — while still answering the Agents chip.
        #expect(fromBot.category == .mention)
        #expect(fromBot.categories == [.mention, .agentActivity])
        #expect(fromBot.matches(.agentActivity))
        #expect(fromBot.matches(.mention))

        // A person's message is not agent activity, which is the half that makes the chip
        // mean anything.
        #expect(fromPerson.categories == [.mention])
        #expect(!fromPerson.matches(.agentActivity))
    }

    @Test("a verified owner attestation is the other authority for agent-ness")
    func ownerAttestationAlsoMarksAnAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let owner = try Fixture()
        let agent = try Fixture()

        // No `bot` role anywhere — this one is an agent purely by its owner's signature,
        // the same either/or `DirectorySnapshot` applies.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.attestedProfile(agent, owner: owner, name: "Bumble", at: 600),
            try ActivityFixtures.message(agent, "research done", in: "room-1", mentions: [me], at: 1000),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.matches(.agentActivity))
        #expect(row.categories == [.mention, .agentActivity])
    }

    @Test("publishing your own agent profile does not put you on the Agents chip")
    func selfPublishedDirectoryEntryIsNotAnAgent() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let impostor = try Fixture()

        // Kind 10100 is self-published under a scope any profile-publishing user holds, so
        // on its own it must buy nothing. Without this, an impostor filters onto the chip
        // your agents' output appears under.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.agentProfile(impostor, name: "Jarvis", at: 600),
            try ActivityFixtures.message(impostor, "trust me", in: "room-1", mentions: [me], at: 1000),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(!row.matches(.agentActivity))
        #expect(row.categories == [.mention])
    }

    @Test("an agent in a thread you are in is Agent activity without naming you")
    func agentRepliesWithoutNamingYouAreNotMentions() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let mine = try Fixture()
        let me = mine.pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let bot = try Fixture()

        let opener = try ActivityFixtures.message(bot, "starting work", in: "room-1", mentions: [me], at: 1000)
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.members(relay, "room-1", people: [me], bots: [bot.pubkey], at: 501),
            opener,
            try ActivityFixtures.message(mine, "go ahead", in: "room-1", replyTo: opener.id, at: 1500),
            // Reaches me by thread participation, names nobody. Agent activity, not a mention.
            try ActivityFixtures.message(bot, "done", in: "room-1", replyTo: opener.id, at: 2000),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.matches(.agentActivity))
        #expect(row.matches(.mention), "the opener named me, and the row carries every category in it")
        #expect(row.latest.content == "done")
    }
}

/// The classification axes, and the query plan they run on.
@Suite("Activity feed classification axes", .timeLimit(.minutes(1)))
struct ActivityFeedAxisTests {
    @Test("an approval's p tag addresses you rather than mentioning you")
    func approvalNamingYouIsNotAMention() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let bot = try Fixture()

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.members(relay, "room-1", people: [me], bots: [bot.pubkey], at: 501),
            try bot.event(
                EventKind(rawValue: 46010), "approve the deploy?",
                tags: [["h", "room-1"], ["p", me]], at: 1000
            ),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        // All three axes at once, and the regression this pins: `categories` used to
        // early-return `[byKind]` the moment a kind matched, so an approval that named you
        // was NOT under Mentions — while three doc comments and a message to JT said it was.
        #expect(row.category == .needsAction)
        #expect(row.matches(.needsAction))
        // The line the relay draws, and the reason: EVERY approval carries a `p` tag naming
        // whoever must approve it — that is how it is addressed. Counting those as mentions
        // would put every approval and every job report into Mentions, which is the one chip
        // JT asked for. `query_mentions` excludes these kinds while `query_needs_action`
        // includes them, joining the same p-tag table (`feed.rs:106` vs `:191`).
        #expect(!row.matches(.mention), "addressed, not mentioned")
        #expect(!row.matches(.agentActivity), "its kind already says what it is")
    }

    @Test("a long message body comes back cut, not whole")
    func bodiesAreCutToThePreviewLength() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()

        let long = String(repeating: "x", count: 5000)
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.message(author, long, in: "room-1", mentions: [me], at: 1000),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        // The scan reaches thousands of events so one busy thread cannot crowd out the rest,
        // and every event past a row's representative one only adds `+1` to a count. Carrying
        // whole bodies for all of them measured ~1 MB of text per commit for text nothing
        // draws. Pinned because removing the `substr` breaks nothing visible.
        #expect(row.latest.content.count == ActivityFeedRead.previewLength)
        #expect(row.latest.content.allSatisfy { $0 == "x" })
    }

    @Test("the activity read seeks its index instead of scanning and sorting the log")
    func readUsesTheKindRecentIndex() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let plan = try await store.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "EXPLAIN QUERY PLAN " + ActivityFeedRead.candidateSQL,
                arguments: ["selfPubkey": String(repeating: "a", count: 64), "scan": 3000]
            ).map { ($0["detail"] as String?) ?? "" }
        }
        let text = plan.joined(separator: "\n")

        // The two findings that made this read linear in the whole event log, pinned so a
        // later edit to the SQL cannot quietly reintroduce either. Both cost ~125 ms per
        // committed transaction at 50k events before `v11.activity-feed`.
        #expect(
            text.contains("event_kind_recent"),
            "the candidate scan must seek (kind, created_at DESC), not SCAN e:\n\(text)"
        )
        // The seek must carry the `created_at` bound, not just `kind`. That is the whole
        // point of the window: `kind IN (…)` gives the planner one range per kind and
        // merging nine ranges into one `created_at` order needs a sort no index can remove,
        // so `USE TEMP B-TREE FOR ORDER BY` stays in this plan and is fine. What matters is
        // what feeds it — with the bound the sort input is thirty days of qualifying events,
        // without it the whole log. Asserting the absence of the sort would have been
        // asserting the wrong thing.
        #expect(
            text.contains("event_kind_recent (kind=? AND created_at>?)"),
            "the window must narrow the index range, or the sort input is unbounded:\n\(text)"
        )
        // `SCAN cm` is not asserted against: on the empty probe database SQLite costs a
        // scan of a zero-row table below any index seek, so the plan says `SCAN cm`
        // whatever indexes exist. The index it needs is asserted directly below instead.
        let indexes = try await store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("channel_member_pubkey"))
        #expect(indexes.contains("event_kind_recent"))
    }
}
