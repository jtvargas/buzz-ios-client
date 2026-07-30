@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// NIP-RS read state: the blob codec, the cross-client ciphertext vector, the
/// grow-only unread math, and that the decrypted table survives a projection
/// version bump (it is precious local state, not a rebuildable projection).
@Suite("Read state", .timeLimit(.minutes(1)))
struct ReadStateTests {
    // MARK: - Blob codec

    @Test("encodes the canonical NIP-RS blob shape with sorted keys")
    func encodesCanonicalBlob() throws {
        let blob = ReadStateBlob(clientID: "hive-ios", contexts: ["room-2": 200, "room-1": 100])
        #expect(try blob.encodedJSON() == #"{"client_id":"hive-ios","contexts":{"room-1":100,"room-2":200},"v":1}"#)
    }

    @Test("decodes a valid blob and drops only the malformed entries")
    func decodesAndSanitizes() throws {
        let big = String(repeating: "x", count: 300) // > 256 bytes, dropped
        let plaintext = """
        {"v":1,"client_id":"c","contexts":{"a":100,"b":"nope","c":1.5,"\(big)":9,"d":2}}
        """
        let blob = try #require(ReadStateBlob.decode(plaintext: plaintext))
        #expect(blob.clientID == "c")
        // Integer entries survive; a string value, a float value, and an oversized key
        // are each dropped while the rest of the blob is still processed.
        #expect(blob.contexts == ["a": 100, "d": 2])
    }

    @Test("rejects an unknown version, a missing client id, and non-object contexts")
    func rejectsInvalidBlobs() {
        #expect(ReadStateBlob.decode(plaintext: #"{"v":2,"client_id":"c","contexts":{}}"#) == nil)
        #expect(ReadStateBlob.decode(plaintext: #"{"v":1,"contexts":{}}"#) == nil)
        #expect(ReadStateBlob.decode(plaintext: #"{"v":1,"client_id":"c","contexts":[]}"#) == nil)
        #expect(ReadStateBlob.decode(plaintext: "not json") == nil)
    }

    @Test("validates the read-state d and t tags")
    func validatesTags() throws {
        let author = try Fixture()
        let valid = try author.event(.readState, "x", tags: [["d", "read-state:abc"], ["t", "read-state"]])
        #expect(ReadState.hasValidTags(valid))
        #expect(ReadState.slotID(from: valid) == "abc")

        let noT = try author.event(.readState, "x", tags: [["d", "read-state:abc"]])
        #expect(!ReadState.hasValidTags(noT))
        let badD = try author.event(.readState, "x", tags: [["d", "sections:abc"], ["t", "read-state"]])
        #expect(!ReadState.hasValidTags(badD))
        let twoD = try author.event(
            .readState, "x", tags: [["d", "read-state:a"], ["d", "read-state:b"], ["t", "read-state"]]
        )
        #expect(!ReadState.hasValidTags(twoD))
    }

    /// The strongest offline proof of cross-device compatibility: our production
    /// signer's decrypt-to-self path recovers the exact plaintext from the NIP-RS
    /// spec's own NIP-44 v2 ciphertext vector (`buzz/docs/nips/NIP-RS.md`, private
    /// key = scalar 1), and the codec parses it. A Desktop-produced blob will decode
    /// here byte-for-byte.
    @Test("decrypts the NIP-RS ciphertext test vector to the canonical blob")
    func decryptsSpecVector() async throws {
        let key = try PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        let signer = InMemorySigner(key)
        let ciphertext = """
        Akt10yui5aDIjfH+xED2Dr1NJ/SGWp85SC/r/bloiLRtj8K59rJrYhcfsNQMoMhpLlvhKqrN0HIGb9/V9BcYKxWV8HT/jjDdvfHLU\
        Vfo688I6WpapcX41GzL4VnGGDdFyUom53odJncjHszS3dpTrG1OKp2x9dtdG+924/+Ne49KN4nztd1pikqYeqQuxflKCmh+VcCFbD\
        clQ8a9NUpqWkPpeoweISVVuZDnP9WFoKG5X6YcpXBWH6wjc69xK4cs6KkJ
        """
        let plaintext = try await signer.decryptToSelf(ciphertext)
        let expected =
            #"{"v":1,"client_id":"test-vector-client","contexts":{"group:general":1700001000,"group:dev":1700000500}}"#
        #expect(plaintext == expected)

        let blob = try #require(ReadStateBlob.decode(plaintext: plaintext))
        #expect(blob.clientID == "test-vector-client")
        #expect(blob.contexts == ["group:general": 1_700_001_000, "group:dev": 1_700_000_500])
    }

    // MARK: - Unread math

    /// Seeds a two-channel store: `room-1` with three others' messages and one of the
    /// reader's own, plus a peer reply; `room-2` empty of messages.
    private func seededStore(_ database: TempDatabase, selfKey: PrivateKey) async throws -> BuzzEventStore {
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfFixture = SignedBy(selfKey)

        let opener = try peer.message("opener", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One", at: 500),
            try meta(relay, "room-2", name: "Two", at: 500),
            opener,
            try peer.message("second", in: "room-1", at: 2000),
            try selfFixture.message("my own", in: "room-1", at: 2500),
            try peer.message("third", in: "room-1", at: 3000),
            // A threaded reply — never counts toward the channel badge.
            try peer.event(
                .channelMessage, "a reply",
                tags: [["h", "room-1"], ["e", opener.id, "", "reply"]], at: 3500
            ),
        ], phase: .backfill)
        try await store.markChannelAccess(
            identity: selfKey.publicKey.hex,
            channel: "room-1",
            state: .active
        )
        try await store.markChannelAccess(
            identity: selfKey.publicKey.hex,
            channel: "room-2",
            state: .active
        )
        return store
    }

    @Test("unread counts others' top-level messages newer than the frontier; own and replies never count")
    func unreadPredicate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let selfKey = try PrivateKey()
        let store = try await seededStore(database, selfKey: selfKey)
        let selfPubkey = selfKey.publicKey.hex

        // No read state yet → every other-authored top-level message is unread. The
        // three peer messages (1000/2000/3000) count; the reader's own (2500) and the
        // reply (3500) do not.
        var rows = try store.channelList(selfPubkey: selfPubkey)
        #expect(rows.first { $0.id == "room-1" }?.unreadCount == 3)

        // Read up to 2000 → the 1000 and 2000 messages are covered (strictly-greater
        // predicate: 2000 is read), leaving only 3000.
        try await store.applyReadState(
            author: selfPubkey, slot: "slot-a", contexts: ["room-1": 2000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )
        rows = try store.channelList(selfPubkey: selfPubkey)
        #expect(rows.first { $0.id == "room-1" }?.unreadCount == 1)

        // Read up to the newest top-level message → caught up.
        try await store.applyReadState(
            author: selfPubkey, slot: "slot-a", contexts: ["room-1": 3000],
            sourceCreatedAt: 20, sourceEventID: "b"
        )
        rows = try store.channelList(selfPubkey: selfPubkey)
        let room1 = try #require(rows.first { $0.id == "room-1" })
        #expect(room1.unreadCount == 0)
        #expect(!room1.hasUnread)
    }

    @Test("a deleted message drops out of the unread count")
    func deletionAwareUnread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfKey = try PrivateKey()

        let newest = try peer.message("newest", in: "room-1", at: 3000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One", at: 500),
            try peer.message("older", in: "room-1", at: 2000),
            newest,
        ], phase: .backfill)
        try await store.markChannelAccess(
            identity: selfKey.publicKey.hex,
            channel: "room-1",
            state: .active
        )
        #expect(try store.channelList(selfPubkey: selfKey.publicKey.hex).first?.unreadCount == 2)

        // The author deletes their own newest: authorized, so it stops counting.
        _ = try await store.ingest(batch: [
            try peer.event(.deletion, "", tags: [["e", newest.id]], at: 3001),
        ], phase: .live)
        #expect(try store.channelList(selfPubkey: selfKey.publicKey.hex).first?.unreadCount == 1)
    }

    @Test("a second device's newer read frontier converges the count via the grow-only max merge")
    func crossDeviceConvergence() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let selfKey = try PrivateKey()
        let store = try await seededStore(database, selfKey: selfKey)
        let selfPubkey = selfKey.publicKey.hex

        // This device read up to 2000; a second device (same identity, different slot)
        // read up to 3000. The effective frontier is the MAX across both slots → 3000,
        // so the badge clears without this device ever marking 3000 itself.
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: ["room-1": 2000],
            sourceCreatedAt: 10, sourceEventID: "p"
        )
        #expect(try store.channelList(selfPubkey: selfPubkey).first { $0.id == "room-1" }?.unreadCount == 1)

        try await store.applyReadState(
            author: selfPubkey, slot: "desktop", contexts: ["room-1": 3000],
            sourceCreatedAt: 11, sourceEventID: "d"
        )
        #expect(try store.channelList(selfPubkey: selfPubkey).first { $0.id == "room-1" }?.unreadCount == 0)
    }

    @Test("an older replaceable blob for a slot never lowers that slot's frontier")
    func replaceableGuard() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let selfKey = try PrivateKey()
        let store = try await seededStore(database, selfKey: selfKey)
        let selfPubkey = selfKey.publicKey.hex

        try await store.applyReadState(
            author: selfPubkey, slot: "s", contexts: ["room-1": 3000],
            sourceCreatedAt: 100, sourceEventID: "newer"
        )
        #expect(try await store.effectiveReadFrontier(context: "room-1") == 3000)

        // An older event for the same slot must be rejected wholesale, not merged.
        try await store.applyReadState(
            author: selfPubkey, slot: "s", contexts: ["room-1": 1000],
            sourceCreatedAt: 90, sourceEventID: "older"
        )
        #expect(try await store.effectiveReadFrontier(context: "room-1") == 3000)

        // A strictly-newer event does replace it.
        try await store.applyReadState(
            author: selfPubkey, slot: "s", contexts: ["room-1": 5000],
            sourceCreatedAt: 110, sourceEventID: "newest"
        )
        #expect(try await store.effectiveReadFrontier(context: "room-1") == 5000)
    }

    // MARK: - Rebuild agreement

    @Test("read state survives a projection version bump — it is precious local state")
    func readStateSurvivesRebuild() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let author = try Fixture()
        let relay = try Fixture()
        let history = [
            try meta(relay, "room-1", name: "One", at: 500),
            try author.message("hello", in: "room-1", at: 1000),
        ]

        var liveProjections: [String: [String]] = [:]
        do {
            let store = try database.open(projectionVersion: 1)
            _ = try await store.ingest(batch: history, phase: .backfill)
            try await store.applyReadState(
                author: author.pubkey, slot: "s", contexts: ["room-1": 900],
                sourceCreatedAt: 10, sourceEventID: "e"
            )
            liveProjections = try await store.projectionSnapshot()
        }

        // Reopen at a bumped version: projections drop and replay, but read_state — a
        // local table decryption produced — must be left untouched.
        let reopened = try database.open(projectionVersion: 2)
        #expect(try await reopened.rowCount("read_state") == 1)
        #expect(try await reopened.effectiveReadFrontier(context: "room-1") == 900)
        // The projections themselves still rebuild to the same rows.
        #expect(try await reopened.projectionSnapshot() == liveProjections)
        #expect(try await reopened.metaValue(Schema.projectionVersionKey) == "2")
    }

    // MARK: - Helpers

    /// A kind-39000 channel-metadata event, relay-signed and addressable by its `d`.
    private func meta(_ relay: Fixture, _ id: String, name: String, at seconds: Int64) throws -> NostrEvent {
        try relay.event(.groupMetadata, #"{"name":"\#(name)"}"#, tags: [["d", id]], at: seconds)
    }
}

/// A minimal signer over a supplied key, for a fixture whose messages the reader
/// "owns" — the store's `Fixture` generates its own key, so this pins authorship to
/// the identity under test.
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
