@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The Phase-4 WS-0 mention read API: a message's `p` tags (indexed in
/// `event_tag`) joined to the `profile` projection, resolved to rendered names for
/// `@`-tokens on any surface.
@Suite("Mentions read API", .timeLimit(.minutes(1)))
struct MentionsTests {
    /// A kind-9 message in `channel` carrying a `p` tag per pubkey in `mentions`.
    private func message(
        _ author: Fixture,
        in channel: String = "room-1",
        mentions: [String],
        at seconds: Int64
    ) throws -> NostrEvent {
        let tags = [["h", channel]] + mentions.map { ["p", $0] }
        return try author.event(.channelMessage, "hey", tags: tags, at: seconds)
    }

    @Test("returns a message's mentions joined to display names, in tag order")
    func mentionsJoinedToProfiles() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        let msg = try message(author, mentions: [alice.pubkey, bob.pubkey], at: 1000)
        _ = try await store.ingest(batch: [
            try alice.event(.metadata, #"{"display_name":"Alice"}"#, at: 900),
            try bob.event(.metadata, #"{"display_name":"Bob"}"#, at: 900),
            msg,
        ], phase: .backfill)

        let refs = try #require(try store.mentions(for: [msg.id])[msg.id])
        #expect(refs.map(\.pubkey) == [alice.pubkey, bob.pubkey])
        #expect(refs.map(\.displayName) == ["Alice", "Bob"])
    }

    @Test("dedupes a pubkey tagged more than once, keeping its first position")
    func dedupesRepeatedTags() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        // alice, bob, alice again: alice must appear once, at her first position.
        let msg = try message(author, mentions: [alice.pubkey, bob.pubkey, alice.pubkey], at: 1000)
        _ = try await store.ingest(batch: [
            try alice.event(.metadata, #"{"display_name":"Alice"}"#, at: 900),
            msg,
        ], phase: .backfill)

        let refs = try #require(try store.mentions(for: [msg.id])[msg.id])
        #expect(refs.map(\.pubkey) == [alice.pubkey, bob.pubkey])
        #expect(refs.first?.displayName == "Alice")
    }

    @Test("falls back to a short key form when the mentioned user has no profile")
    func fallsBackWithoutProfile() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let stranger = try Fixture()

        let msg = try message(author, mentions: [stranger.pubkey], at: 1000)
        _ = try await store.ingest(batch: [msg], phase: .backfill)

        let refs = try #require(try store.mentions(for: [msg.id])[msg.id])
        // Matches TimelineRow.displayName's fallback: the first eight key chars.
        #expect(refs.map(\.displayName) == [String(stranger.pubkey.prefix(8))])
    }

    @Test("keys each message's mentions independently and omits a message with none")
    func perMessageKeyingAndOmission() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let alice = try Fixture()

        let mentioning = try message(author, mentions: [alice.pubkey], at: 1000)
        let plain = try message(author, mentions: [], at: 1001)
        _ = try await store.ingest(batch: [
            try alice.event(.metadata, #"{"display_name":"Alice"}"#, at: 900),
            mentioning,
            plain,
        ], phase: .backfill)

        let result = try store.mentions(for: [mentioning.id, plain.id])
        #expect(result[mentioning.id]?.map(\.pubkey) == [alice.pubkey])
        // A message with no p tags is simply absent — a missing key means "none".
        #expect(result[plain.id] == nil)
    }

    @Test("returns nothing for an empty id list")
    func emptyInput() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        #expect(try store.mentions(for: []).isEmpty)
    }
}
