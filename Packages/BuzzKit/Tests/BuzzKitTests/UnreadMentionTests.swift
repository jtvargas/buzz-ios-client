@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The sidebar's mention badge: how many of a channel's unread messages are addressed to
/// the reader.
///
/// Its own suite rather than a section of ``ReadStateTests``, because it is a different
/// claim over the same machinery: read state decides *which* messages are unread, and
/// this decides which of those are yours. Both counts come from one `channelList` read,
/// which is what makes the badge's number impossible to disagree with the row's.
@Suite("Unread mentions", .timeLimit(.minutes(1)))
struct UnreadMentionTests {
    /// A channel holding three unread messages addressed to the reader, plus every kind
    /// of message that looks like one and is not.
    private func seededStore(
        _ database: TempDatabase,
        relay: Fixture,
        peer: Fixture,
        selfKey: PrivateKey
    ) async throws -> BuzzEventStore {
        let store = try database.open()
        let selfPubkey = selfKey.publicKey.hex
        let opener = try peer.message("opener", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One", at: 500),
            opener,
            // Two messages address the reader; a third does not.
            try peer.event(
                .channelMessage, "hey @you",
                tags: [["h", "room-1"], ["p", selfPubkey]], at: 2000
            ),
            try peer.event(
                .channelMessage, "and again",
                tags: [["h", "room-1"], ["p", selfPubkey]], at: 3000
            ),
            // Tagged twice in one message: a badge counts messages, not tags.
            try peer.event(
                .channelMessage, "@you @you",
                tags: [["h", "room-1"], ["p", selfPubkey], ["p", selfPubkey]], at: 4000
            ),
            // Addressed to somebody else.
            try peer.event(
                .channelMessage, "hey @other",
                tags: [["h", "room-1"], ["p", relay.pubkey]], at: 5000
            ),
            // The reader's own message naming themselves never counts.
            try SignedBy(selfKey).message("note to self", in: "room-1", at: 6000),
            // A mention inside a thread reply belongs to that thread, not to the
            // channel's badge — the same rule `unreadCount` applies.
            try peer.event(
                .channelMessage, "in a thread @you",
                tags: [["h", "room-1"], ["e", opener.id, "", "reply"], ["p", selfPubkey]],
                at: 7000
            ),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: selfPubkey, channel: "room-1", state: .active)
        return store
    }

    @Test("the mention count is the subset of unread messages that p-tag the reader")
    func unreadMentionCount() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let selfKey = try PrivateKey()
        let selfPubkey = selfKey.publicKey.hex
        let store = try await seededStore(
            database, relay: try Fixture(), peer: try Fixture(), selfKey: selfKey
        )

        let room = try #require(try store.channelList(selfPubkey: selfPubkey)
            .first { $0.id == "room-1" })
        #expect(room.unreadMentionCount == 3)
        // Never more than the unread count it is a subset of.
        #expect(room.unreadMentionCount <= room.unreadCount)
    }

    @Test("the badge falls as the read frontier passes each mention")
    func mentionCountFollowsTheFrontier() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let selfKey = try PrivateKey()
        let selfPubkey = selfKey.publicKey.hex
        let store = try await seededStore(
            database, relay: try Fixture(), peer: try Fixture(), selfKey: selfKey
        )

        // Reading past the first two mentions leaves the third.
        try await store.applyReadState(
            author: selfPubkey, slot: "slot-a", contexts: ["room-1": 3000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )
        #expect(try store.channelList(selfPubkey: selfPubkey)
            .first { $0.id == "room-1" }?.unreadMentionCount == 1)

        // Catching up clears the badge.
        try await store.applyReadState(
            author: selfPubkey, slot: "slot-a", contexts: ["room-1": 7000],
            sourceCreatedAt: 20, sourceEventID: "b"
        )
        #expect(try store.channelList(selfPubkey: selfPubkey)
            .first { $0.id == "room-1" }?.unreadMentionCount == 0)
    }

    @Test("a deleted mention stops counting, and no identity means no mentions")
    func mentionCountEdges() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfPubkey = try PrivateKey().publicKey.hex

        let mention = try peer.event(
            .channelMessage, "@you",
            tags: [["h", "room-1"], ["p", selfPubkey]], at: 2000
        )
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One", at: 500),
            mention,
        ], phase: .backfill)
        try await store.markChannelAccess(identity: selfPubkey, channel: "room-1", state: .active)
        #expect(try store.channelList(selfPubkey: selfPubkey).first?.unreadMentionCount == 1)

        // Without a local identity there is nobody for a message to be addressed to.
        #expect(try store.channelList(selfPubkey: nil).first?.unreadMentionCount == 0)

        _ = try await store.ingest(batch: [
            try peer.event(.deletion, "", tags: [["e", mention.id]], at: 2001),
        ], phase: .live)
        #expect(try store.channelList(selfPubkey: selfPubkey).first?.unreadMentionCount == 0)
    }

    /// A `p` tag is a raw string written by whichever client sent the message and never
    /// decoded, so the tag comparison is `COLLATE NOCASE` where every `event.pubkey`
    /// comparison around it is binary. Missing a mention because another client
    /// upper-cased a key is the worse failure, and nothing else pins the collation —
    /// dropping it leaves a badge that is quietly short by however many peers write hex
    /// in upper case.
    @Test("a mention counts however the sending client cased the key")
    func mentionTagIsCaseInsensitive() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfPubkey = try PrivateKey().publicKey.hex

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One", at: 500),
            try peer.event(
                .channelMessage, "lower @you",
                tags: [["h", "room-1"], ["p", selfPubkey]], at: 2000
            ),
            try peer.event(
                .channelMessage, "upper @you",
                tags: [["h", "room-1"], ["p", selfPubkey.uppercased()]], at: 3000
            ),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: selfPubkey, channel: "room-1", state: .active)

        #expect(try store.channelList(selfPubkey: selfPubkey).first?.unreadMentionCount == 2)
    }

    private func meta(_ relay: Fixture, _ id: String, name: String, at seconds: Int64) throws -> NostrEvent {
        try relay.event(.groupMetadata, #"{"name":"\#(name)"}"#, tags: [["d", id]], at: seconds)
    }
}

/// A fixture that signs as one supplied identity, so a test can pin authorship to the key
/// it treats as the local reader. The store's own ``Fixture`` generates its key.
private struct SignedBy {
    let key: PrivateKey
    init(_ key: PrivateKey) { self.key = key }

    func message(_ content: String, in channel: String, at seconds: Int64) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: .channelMessage,
            content: content,
            tags: [["h", channel]],
            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            with: key
        )
    }
}
