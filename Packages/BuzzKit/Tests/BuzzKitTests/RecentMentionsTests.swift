@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

/// The composer's "recent usage" signal: who the local identity has `@`-named lately.
@Suite("Recent mentions", .timeLimit(.minutes(1)))
struct RecentMentionsTests {
    // MARK: - Ordering

    @Test("ranks each identity by its newest mention, not its first")
    func ordersByRecency() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let me = SignedBy(key)
        let ada = try Fixture(), bo = try Fixture(), cy = try Fixture()

        _ = try await store.ingest(batch: [
            // Ada is mentioned first of all and then again last-but-one. Ranking on the
            // *first* mention — the shape a plain `ORDER BY created_at` without the
            // per-identity MAX would produce — puts Ada at the tail; ranking on the
            // newest puts Ada second, which is where someone just named expects to be.
            try me.message("hi", in: "room-1", mentioning: [ada.pubkey], at: 1000),
            try me.message("hey", in: "room-1", mentioning: [bo.pubkey], at: 2000),
            try me.message("again", in: "room-1", mentioning: [ada.pubkey], at: 3000),
            try me.message("last", in: "room-1", mentioning: [cy.pubkey], at: 4000),
        ], phase: .backfill)

        let recent = try store.recentMentions(by: key.publicKey.hex, limit: 10)
        #expect(recent.pubkeys == [cy.pubkey, ada.pubkey, bo.pubkey].map { $0.lowercased() })
        #expect(recent.rank(of: cy.pubkey) == 0)
        #expect(recent.rank(of: ada.pubkey) == 1)
        #expect(recent.rank(of: bo.pubkey) == 2)
    }

    @Test("two identities named in one message tie, and the tie is broken the same way every read")
    func tiesAreTotalAndStable() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let ada = try Fixture(), bo = try Fixture()

        _ = try await store.ingest(batch: [
            try SignedBy(key).message(
                "both", in: "room-1", mentioning: [ada.pubkey, bo.pubkey], at: 1000
            ),
        ], phase: .backfill)

        // Named in one message, so there is no "more recently" between them and tag order
        // is deliberately *not* the answer — a mention is not more recent for having been
        // typed first in the same sentence. The order is by key instead, which says
        // nothing about the pair but is the same on every read: the panel must not
        // reshuffle between keystrokes.
        let first = try store.recentMentions(by: key.publicKey.hex, limit: 10)
        #expect(Set(first.pubkeys) == Set([ada.pubkey, bo.pubkey].map { $0.lowercased() }))
        #expect(first.pubkeys == [ada.pubkey, bo.pubkey].map { $0.lowercased() }.sorted())
        #expect(try store.recentMentions(by: key.publicKey.hex, limit: 10).pubkeys == first.pubkeys)
    }

    @Test("rank is case-insensitive and absent for someone never mentioned")
    func rankLookup() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let ada = try Fixture(), stranger = try Fixture()

        _ = try await store.ingest(batch: [
            try SignedBy(key).message("hi", in: "room-1", mentioning: [ada.pubkey], at: 1000),
        ], phase: .backfill)

        let recent = try store.recentMentions(by: key.publicKey.hex, limit: 10)
        #expect(recent.rank(of: ada.pubkey.uppercased()) == 0)
        #expect(recent.rank(of: stranger.pubkey) == nil)
    }

    @Test("keeps only the most recent `limit` identities")
    func honoursLimit() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let me = SignedBy(key)
        let people = try (0 ..< 5).map { _ in try Fixture() }

        _ = try await store.ingest(batch: people.enumerated().map { index, person in
            try me.message("m", in: "room-1", mentioning: [person.pubkey], at: Int64(1000 + index))
        }, phase: .backfill)

        let recent = try store.recentMentions(by: key.publicKey.hex, limit: 2)
        #expect(recent.pubkeys == [people[4].pubkey, people[3].pubkey].map { $0.lowercased() })
    }

    // MARK: - What counts

    @Test("only the local identity's own mentions count")
    func excludesOtherAuthors() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let someoneElse = try Fixture()
        let ada = try Fixture(), bo = try Fixture()

        _ = try await store.ingest(batch: [
            try SignedBy(key).message("mine", in: "room-1", mentioning: [ada.pubkey], at: 1000),
            // A louder, more recent mention by somebody else. Ranking on it would order
            // the panel by a stranger's habits.
            try someoneElse.event(
                .channelMessage, "theirs",
                tags: [["h", "room-1"], ["p", bo.pubkey]], at: 9000
            ),
        ], phase: .backfill)

        #expect(try store.recentMentions(by: key.publicKey.hex, limit: 10).pubkeys
            == [ada.pubkey.lowercased()])
    }

    @Test("a `p` tag on a non-message kind is not a mention")
    func excludesOtherKinds() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let me = SignedBy(key)
        let peer = try Fixture(), ada = try Fixture()

        _ = try await store.ingest(batch: [
            try me.message("hi", in: "room-1", mentioning: [ada.pubkey], at: 1000),
            // A direct-message open `p`-tags the *recipient*. Counting it would float
            // every DM peer above the people actually being named.
            try NostrEvent.signed(
                kind: .directMessageOpen, content: "",
                tags: [["p", peer.pubkey]],
                createdAt: Date(timeIntervalSince1970: 9000), with: key
            ),
        ], phase: .backfill)

        #expect(try store.recentMentions(by: key.publicKey.hex, limit: 10).pubkeys
            == [ada.pubkey.lowercased()])
    }

    @Test("no identity, or a non-positive limit, yields nothing rather than everyone's mentions")
    func requiresAnIdentity() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let ada = try Fixture()

        _ = try await store.ingest(batch: [
            try SignedBy(key).message("hi", in: "room-1", mentioning: [ada.pubkey], at: 1000),
        ], phase: .backfill)

        #expect(try store.recentMentions(by: nil, limit: 10).isEmpty)
        #expect(try store.recentMentions(by: "", limit: 10).isEmpty)
        #expect(try store.recentMentions(by: key.publicKey.hex, limit: 0).isEmpty)
    }

    // MARK: - Pending sends

    @Test("a queued send's mentions rank above an already-acknowledged one")
    func countsPendingSends() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let ada = try Fixture(), bo = try Fixture()

        _ = try await store.ingest(batch: [
            try SignedBy(key).message("sent", in: "room-1", mentioning: [ada.pubkey], at: 1000),
        ], phase: .backfill)

        // The relay has not acknowledged this one yet, so it exists only in the outbox —
        // and it is the mention the author made most recently.
        _ = try await store.enqueue(
            content: "queued",
            in: "room-1",
            tags: [["h", "room-1"], ["p", bo.pubkey]],
            with: InMemorySigner(key),
            createdAt: Date(timeIntervalSince1970: 2000)
        )

        #expect(try store.recentMentions(by: key.publicKey.hex, limit: 10).pubkeys
            == [bo.pubkey, ada.pubkey].map { $0.lowercased() })
    }

    @Test("a stale queued send does not outrank a newer acknowledged one")
    func pendingSendsMergeOnTime() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let key = try PrivateKey()
        let ada = try Fixture(), bo = try Fixture()

        // Queued long ago and never accepted — a failed send sitting in the queue.
        _ = try await store.enqueue(
            content: "stuck",
            in: "room-1",
            tags: [["h", "room-1"], ["p", bo.pubkey]],
            with: InMemorySigner(key),
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        _ = try await store.ingest(batch: [
            try SignedBy(key).message("sent", in: "room-1", mentioning: [ada.pubkey], at: 2000),
        ], phase: .backfill)

        #expect(try store.recentMentions(by: key.publicKey.hex, limit: 10).pubkeys
            == [ada.pubkey, bo.pubkey].map { $0.lowercased() })
    }
}

/// A fixture that signs as one supplied identity, so a test can pin authorship to the
/// key it treats as the local user. The store's own ``Fixture`` generates its key.
private struct SignedBy {
    let key: PrivateKey
    init(_ key: PrivateKey) { self.key = key }

    func message(
        _ content: String,
        in channel: String,
        mentioning pubkeys: [String] = [],
        at seconds: Int64
    ) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: .channelMessage,
            content: content,
            tags: [["h", channel]] + pubkeys.map { ["p", $0] },
            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            with: key
        )
    }
}
