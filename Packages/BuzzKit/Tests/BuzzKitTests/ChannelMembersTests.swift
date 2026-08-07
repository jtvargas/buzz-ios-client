@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The Phase-4 WS-0 channel-roster read API: the relay-signed `channel_member`
/// roster (kind 39002) joined to the `profile` projection (kind 0), read fresh so a
/// `ValueObservation` keeps a member list live.
@Suite("Channel members read API", .timeLimit(.minutes(1)))
struct ChannelMembersTests {
    /// Signs a kind-39002 roster for `channel` naming each `(pubkey, role?)` in the
    /// shape the relay actually signs — `["p", pubkey, "", role]`, the role in the
    /// petname slot behind an empty relay hint.
    ///
    /// This used to build `["p", pubkey, role]`, which is the shape kind *39001* uses
    /// and the one the projector was reading. Written to match the reader rather than
    /// the wire, it agreed with the bug and kept every roster test green while
    /// `channel_member.role` was `""` on every real device.
    private func roster(
        _ relay: Fixture,
        channel: String,
        members: [(pubkey: String, role: String?)],
        at seconds: Int64
    ) throws -> NostrEvent {
        var tags: [[String]] = [["d", channel]]
        for member in members {
            tags.append(member.role.map { ["p", member.pubkey, "", $0] } ?? ["p", member.pubkey])
        }
        return try relay.event(.groupMembers, "", tags: tags, at: seconds)
    }

    @Test("returns the roster joined to profiles, in a stable name-then-key order")
    func rosterJoinedToProfiles() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        _ = try await store.ingest(batch: [
            try alice.event(.metadata, #"{"display_name":"Alice","picture":"a.png","nip05":"alice@buzz"}"#, at: 900),
            try bob.event(.metadata, #"{"display_name":"Bob"}"#, at: 900),
            try roster(relay, channel: "room-1", members: [
                (alice.pubkey, "admin"),
                (bob.pubkey, nil),
            ], at: 1000),
        ], phase: .backfill)

        let members = try store.channelMembers("room-1")
        // Alice before Bob by display name; both carry their joined profile + role.
        #expect(members.map(\.pubkey) == [alice.pubkey, bob.pubkey])
        #expect(members.map(\.displayName) == ["Alice", "Bob"])
        #expect(members[0].picture == "a.png")
        #expect(members[0].nip05 == "alice@buzz")
        #expect(members[0].role == "admin")
        #expect(members[1].role == nil)
    }

    @Test("keeps a member that has no profile row, sorted after the named members")
    func memberWithoutProfile() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let named = try Fixture()
        let unnamed = try Fixture()

        _ = try await store.ingest(batch: [
            try named.event(.metadata, #"{"display_name":"Zara"}"#, at: 900),
            try roster(relay, channel: "room-1", members: [
                (named.pubkey, nil),
                (unnamed.pubkey, nil),
            ], at: 1000),
        ], phase: .backfill)

        let members = try store.channelMembers("room-1")
        // The profileless member is present, merely unnamed, and sorts last despite
        // "Zara" being alphabetically late — nameless always trails named.
        #expect(members.map(\.pubkey) == [named.pubkey, unnamed.pubkey])
        #expect(members[0].displayName == "Zara")
        #expect(members[1].displayName == nil)
        #expect(members[1].picture == nil)
        #expect(members[1].nip05 == nil)
    }

    @Test("a member of one channel does not leak into another")
    func rosterIsScopedToChannel() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let inRoom1 = try Fixture()
        let inRoom2 = try Fixture()

        _ = try await store.ingest(batch: [
            try roster(relay, channel: "room-1", members: [(inRoom1.pubkey, nil)], at: 1000),
            try roster(relay, channel: "room-2", members: [(inRoom2.pubkey, nil)], at: 1000),
        ], phase: .backfill)

        #expect(try store.channelMembers("room-1").map(\.pubkey) == [inRoom1.pubkey])
        #expect(try store.channelMembers("room-2").map(\.pubkey) == [inRoom2.pubkey])
    }

    @Test("batch roster read groups every member without per-channel queries")
    func batchRosterRead() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let shared = try Fixture()
        let room1Only = try Fixture()

        _ = try await store.ingest(batch: [
            try roster(relay, channel: "room-1", members: [
                (shared.pubkey, nil),
                (room1Only.pubkey, nil),
            ], at: 1_000),
            try roster(relay, channel: "room-2", members: [
                (shared.pubkey, nil),
            ], at: 1_000),
        ], phase: .backfill)

        let rosters = try store.channelMemberPubkeysByChannel()
        #expect(rosters["room-1"] == Set([shared.pubkey, room1Only.pubkey]))
        #expect(rosters["room-2"] == Set([shared.pubkey]))
    }

    @Test("returns an empty roster for a channel with no members")
    func unknownChannelIsEmpty() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        #expect(try store.channelMembers("nope").isEmpty)
    }
}
