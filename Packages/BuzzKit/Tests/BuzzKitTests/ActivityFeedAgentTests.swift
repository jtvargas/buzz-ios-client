@testable import BuzzKit
import Foundation
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

    @Test("the relay's agent directory is the other authority for agent-ness")
    func agentDirectoryAlsoMarksAnAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let agent = try Fixture()

        // No `bot` role anywhere — this one is an agent purely by being in the directory,
        // the same either/or `DirectorySnapshot` applies.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.agentProfile(agent, name: "Bumble", at: 600),
            try ActivityFixtures.message(agent, "research done", in: "room-1", mentions: [me], at: 1000),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.matches(.agentActivity))
        #expect(row.categories == [.mention, .agentActivity])
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
