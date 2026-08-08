@testable import BuzzKit
import GRDB
import NostrCore
import Testing

@Suite("Local search", .timeLimit(.minutes(1)))
struct MessageSearchTests {
    @Test("migration backfills immutable message and edit text, and triggers stay in sync")
    func migrationBackfillAndTriggers() throws {
        let database = TempDatabase()
        defer { database.remove() }
        let queue = try DatabaseQueue(path: database.path)

        try queue.write { db in
            try Schema.createLogTables(db)
            try insertRawEvent(db, id: "message", kind: 9, content: "legacy alpha")
            try insertRawEvent(db, id: "edit", kind: 40003, content: "revised beta")
            try insertRawEvent(db, id: "reaction", kind: 7, content: "reaction gamma")
            try Schema.createMessageSearch(db)

            #expect(try matchCount(db, "legacy") == 1)
            #expect(try matchCount(db, "revised") == 1)
            #expect(try matchCount(db, "reaction") == 0)

            try insertRawEvent(db, id: "live", kind: 9, content: "arriving delta")
            #expect(try matchCount(db, "arriving") == 1)
            try db.execute(sql: "DELETE FROM event WHERE id = 'live'")
            #expect(try matchCount(db, "arriving") == 0)

            try db.execute(sql: "INSERT INTO message_search(message_search) VALUES ('rebuild')")
            #expect(try matchCount(db, "legacy") == 1)
            try db.execute(sql: """
            INSERT INTO message_search(message_search, rank) VALUES ('integrity-check', 1)
            """)
        }
    }

    @Test("newest authorized edit replaces the original in search")
    func authorizedEditWins() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let message = try author.message("original wording", at: 1_000)

        _ = try await store.ingest(batch: [
            message,
            author.event(.messageEdit, "first revision", tags: [["e", message.id]], at: 1_001),
            author.event(.messageEdit, "current revision", tags: [["e", message.id]], at: 1_002),
        ], phase: .backfill)

        #expect(try store.searchMessages(query: "original").isEmpty)
        #expect(try store.searchMessages(query: "first").isEmpty)
        let hit = try #require(try store.searchMessages(query: "current").first)
        #expect(hit.id == message.id)
        #expect(hit.content == "current revision")
    }

    @Test("owner edits are eligible and stranger edits never leak")
    func editAuthority() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let owner = try Fixture()
        let agent = try Fixture()
        let stranger = try Fixture()
        let message = try agent.event(
            .channelMessage,
            "agent original",
            tags: [["h", "room-1"], try owner.authTag(authorizing: agent.pubkey)],
            at: 1_000
        )

        _ = try await store.ingest(batch: [
            message,
            stranger.event(.messageEdit, "stolen secret", tags: [["e", message.id]], at: 1_001),
            owner.event(.messageEdit, "owner revision", tags: [["e", message.id]], at: 1_002),
        ], phase: .backfill)

        #expect(try store.searchMessages(query: "stolen").isEmpty)
        let hit = try #require(try store.searchMessages(query: "owner").first)
        #expect(hit.id == message.id)
        #expect(hit.content == "owner revision")
    }

    @Test("authorized deletions disappear and unauthorized deletions do not")
    func deletionAuthority() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let stranger = try Fixture()
        let deleted = try author.message("removed phrase", at: 1_000)
        let visible = try author.message("visible phrase", at: 1_001)

        _ = try await store.ingest(batch: [
            deleted,
            visible,
            author.event(.deletion, tags: [["e", deleted.id]], at: 1_002),
            stranger.event(.deletion, tags: [["e", visible.id]], at: 1_003),
        ], phase: .backfill)

        #expect(try store.searchMessages(query: "removed").isEmpty)
        #expect(try store.searchMessages(query: "visible").map(\.id) == [visible.id])
    }

    @Test("relay tombstones and verified owner deletions disappear")
    func widenedDeletionAuthority() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let owner = try Fixture()
        let agent = try Fixture()
        let moderator = try Fixture()
        let owned = try agent.event(
            .channelMessage,
            "owner removed",
            tags: [["h", "room-1"], try owner.authTag(authorizing: agent.pubkey)],
            at: 1_000
        )
        let moderated = try agent.message("moderator removed", at: 1_001)

        _ = try await store.ingest(batch: [
            owned,
            moderated,
            owner.event(.deletion, tags: [["e", owned.id]], at: 1_002),
            moderator.event(.groupDeleteEvent, tags: [["e", moderated.id]], at: 1_003),
        ], phase: .backfill)

        #expect(try store.searchMessages(query: "owner").isEmpty)
        #expect(try store.searchMessages(query: "moderator").isEmpty)
    }

    @Test("projection rebuild does not repopulate the durable FTS index")
    func projectionRebuildDoesNotReindex() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let message = try author.message("durable sentinel", at: 1_000)
        _ = try await store.ingest(batch: [message], phase: .backfill)

        try await store.executeForTest("""
        INSERT INTO message_search(message_search, rowid, content)
        SELECT 'delete', rowid, content FROM event WHERE id = '\(message.id)'
        """)
        #expect(try store.searchMessages(query: "sentinel").isEmpty)

        try await store.rebuildProjections()
        #expect(try store.searchMessages(query: "sentinel").isEmpty)

        try await store.executeForTest(
            "INSERT INTO message_search(message_search) VALUES ('rebuild')"
        )
        #expect(try store.searchMessages(query: "sentinel").map(\.id) == [message.id])
    }

    @Test("highlight ranges use UTF-16 offsets and matching removes diacritics")
    func highlightRanges() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        _ = try await store.ingest(
            batch: [try author.message("🐝 Café and cafe", at: 1_000)],
            phase: .backfill
        )

        let hit = try #require(try store.searchMessages(query: "cafe").first)
        #expect(hit.content == "🐝 Café and cafe")
        #expect(hit.matchRanges == [
            SearchMatchRange(location: 3, length: 4),
            SearchMatchRange(location: 12, length: 4),
        ])
    }

    @Test("channel scope is applied before the result limit")
    func channelScope() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            author.message("shared term", in: "room-1", at: 1_000),
            author.message("shared term", in: "room-2", at: 1_001),
        ], phase: .backfill)

        let hits = try store.searchMessages(query: "shared", channelID: "room-1", limit: 1)
        #expect(hits.count == 1)
        #expect(hits.first?.channelID == "room-1")
    }

    @Test("direct-message results carry relay-authored DM identity")
    func directMessageIdentity() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            relay.event(
                .groupMetadata,
                #"{"name":"DM"}"#,
                tags: [["d", "dm-room"], ["t", "dm"]],
                at: 900
            ),
            author.message("private searchable", in: "dm-room", at: 1_000),
        ], phase: .backfill)

        let hit = try #require(try store.searchMessages(query: "searchable").first)
        #expect(hit.channelID == "dm-room")
        #expect(hit.isDirectMessage)
    }

    @Test("people and channels are scored with exact highlight ranges")
    func peopleAndChannels() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let person = try Fixture()
        let reader = try Fixture()
        _ = try await store.ingest(batch: [
            person.event(.metadata, #"{"display_name":"José Rivera"}"#, at: 800),
            relay.event(
                .groupMetadata,
                #"{"name":"Café Planning","about":"Weekly roadmap"}"#,
                tags: [["d", "planning"]],
                at: 900
            ),
            relay.event(
                .groupMembers,
                tags: [["d", "planning"], ["p", reader.pubkey], ["p", person.pubkey]],
                at: 901
            ),
        ], phase: .backfill)

        let people = try store.searchLocal(query: "jose", selfPubkey: reader.pubkey)
        let personHit = try #require(people.people.first)
        #expect(personHit.id == person.pubkey)
        #expect(personHit.match.text == "José Rivera")
        #expect(personHit.match.ranges == [SearchMatchRange(location: 0, length: 4)])

        let channels = try store.searchLocal(query: "cafe", selfPubkey: reader.pubkey)
        let channelHit = try #require(channels.channels.first)
        #expect(channelHit.id == "planning")
        #expect(channelHit.match.text == "Café Planning")
        #expect(channelHit.match.ranges == [SearchMatchRange(location: 0, length: 4)])
    }

    @Test("wipe removes event text and search tokens")
    func wipeClearsSearch() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        _ = try await store.ingest(
            batch: [try author.message("identity secret", at: 1_000)],
            phase: .backfill
        )
        #expect(try store.searchMessages(query: "secret").count == 1)

        try await store.wipe()

        #expect(try store.searchMessages(query: "secret").isEmpty)
        #expect(try await store.rowCount("event") == 0)
    }

    private func insertRawEvent(
        _ db: Database,
        id: String,
        kind: Int,
        content: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO event
                (id, pubkey, created_at, kind, content, tags, sig, h, received_at)
            VALUES (?, 'author', 1000, ?, ?, '[]', 'sig', 'room-1', 1000)
            """,
            arguments: [id, kind, content]
        )
    }

    private func matchCount(_ db: Database, _ term: String) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM message_search WHERE message_search MATCH ?",
            arguments: ["\"\(term)\""]
        ) ?? 0
    }
}

extension MessageSearchTests {
    @Test("authorization may return a short page after the bounded candidate window")
    func boundedCandidateWindow() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        var batch: [NostrEvent] = []

        for index in 0 ..< BuzzEventStore.searchCandidateWindowMultiplier {
            let message = try author.message(
                "shared shared shared hidden \(index)",
                at: 1_000 + Int64(index)
            )
            batch.append(message)
            batch.append(
                author.event(
                    .deletion,
                    tags: [["e", message.id]],
                    at: 2_000 + Int64(index)
                )
            )
        }
        batch.append(try author.message("shared visible", at: 3_000))
        _ = try await store.ingest(batch: batch, phase: .backfill)

        #expect(try store.searchMessages(query: "shared", limit: 1).isEmpty)
    }
}
