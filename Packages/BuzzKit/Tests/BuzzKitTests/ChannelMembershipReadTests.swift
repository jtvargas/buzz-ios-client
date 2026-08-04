@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The two reads that separate *joined* from *discoverable*, and the name resolution the
/// starter-channel seeding depends on.
///
/// The distinction they draw is the whole membership fix: the relay serves every open
/// channel to any key, so the projections hold metadata and rosters for channels nobody
/// on this device has joined. Everything that costs a request at rest reads
/// ``BuzzEventStore/joinedChannelIDs(identity:)``; everything a browse surface lists reads
/// ``BuzzEventStore/browsableChannels(identity:)``. Confusing the two in either direction
/// is a live defect — one way the phone subscribes to a whole relay, the other way half
/// the catalogue becomes invisible.
@Suite("Channel membership reads", .timeLimit(.minutes(1)))
struct ChannelMembershipReadTests {
    // MARK: - Joined vs discoverable

    @Test("membership is the roster naming this identity, not every channel on the relay")
    func joinedIsTheRoster() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()
        let peer = try Fixture()

        try await store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "mine"], ["name", "Mine"]]),
            relay.event(.groupMembers, "", tags: [["d", "mine"], ["p", identity.pubkey], ["p", peer.pubkey]]),
            relay.event(.groupMetadata, "", tags: [["d", "theirs"], ["name", "Theirs"]]),
            relay.event(.groupMembers, "", tags: [["d", "theirs"], ["p", peer.pubkey]]),
        ], phase: .backfill)

        #expect(try store.joinedChannelIDs(identity: identity.pubkey) == ["mine"])
        // The channel this identity has never joined is still in the projections, in full.
        // That is what makes a browse screen a read rather than a fetch.
        let browsable = try store.browsableChannels(identity: identity.pubkey)
        #expect(browsable.map(\.id) == ["mine", "theirs"])
        #expect(browsable.map(\.isJoined) == [true, false])
        #expect(browsable.map(\.memberCount) == [2, 1])
    }

    /// The relay hex-encodes lowercase and `channel_member_pubkey` is a case-sensitive
    /// index, so the comparison is exact against a lowercased parameter. A caller handing
    /// in an uppercased hex must still be recognised, or the sidebar empties.
    @Test("an uppercased identity still matches the roster the relay wrote")
    func identityCaseIsNormalised() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()

        try await store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "mine"], ["name", "Mine"]]),
            relay.event(.groupMembers, "", tags: [["d", "mine"], ["p", identity.pubkey]]),
        ], phase: .backfill)

        #expect(try store.joinedChannelIDs(identity: identity.pubkey.uppercased()) == ["mine"])
    }

    @Test("a direct message is not something anyone browses or joins")
    func directMessagesAreExcluded() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()

        try await store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"], ["t", "stream"]]),
            relay.event(.groupMetadata, "", tags: [["d", "chat"], ["name", "Chat"], ["t", "dm"]]),
            relay.event(.groupMembers, "", tags: [["d", "chat"], ["p", identity.pubkey]]),
        ], phase: .backfill)

        #expect(try store.browsableChannels(identity: identity.pubkey).map(\.id) == ["room"])
        // Still a membership, though — the subscription set has to keep delivering it.
        #expect(try store.joinedChannelIDs(identity: identity.pubkey) == ["chat"])
    }

    @Test("archived and private travel with the channel a browse screen filters on")
    func flagsAreCarried() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()

        try await store.ingest(batch: [
            relay.event(
                .groupMetadata, "",
                tags: [["d", "attic"], ["name", "Attic"], ["archived", "true"]]
            ),
            // NIP-29 marks a closed group with a bare `private` tag.
            relay.event(.groupMetadata, "", tags: [["d", "hush"], ["name", "Hush"], ["private"]]),
        ], phase: .backfill)

        let byID = try Dictionary(
            uniqueKeysWithValues: store.browsableChannels(identity: identity.pubkey).map { ($0.id, $0) }
        )
        #expect(byID["attic"]?.isArchived == true)
        #expect(byID["hush"]?.isPrivate == true)
        #expect(byID["attic"]?.isPrivate == false)
        #expect(byID["hush"]?.isArchived == false)
    }

    // MARK: - Starter resolution

    /// A relay that has hosted more than one community holds more than one `general`, and
    /// this device's projection holds every one it can see. Joining the wrong one puts the
    /// reader in an empty room and leaves the real conversation unjoined.
    @Test("a duplicated starter name resolves to the channel with the members in it")
    func widestRosterWinsTheName() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let members = try (0 ..< 3).map { _ in try Fixture() }

        try await store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "busy"], ["name", "general"]]),
            relay.event(
                .groupMembers, "",
                tags: [["d", "busy"]] + members.map { ["p", $0.pubkey] }
            ),
            relay.event(.groupMetadata, "", tags: [["d", "quiet"], ["name", "general"]]),
            relay.event(.groupMembers, "", tags: [["d", "quiet"], ["p", members[0].pubkey]]),
        ], phase: .backfill)

        #expect(try await store.starterChannelIDs(named: ["general"]) == ["busy"])
    }

    @Test("a starter the relay cannot take a self-join for is passed over")
    func unjoinableStartersAreSkipped() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        try await store.ingest(batch: [
            // Archived: the relay refuses any h-tagged event with `invalid: channel is
            // archived`, so publishing a join here would be asking a question with a
            // known answer.
            relay.event(
                .groupMetadata, "",
                tags: [["d", "old-general"], ["name", "general"], ["archived", "true"]]
            ),
            relay.event(.groupMetadata, "", tags: [["d", "live-general"], ["name", "general"]]),
            // Private: `restricted: channel is private — request an invitation`.
            relay.event(
                .groupMetadata, "",
                tags: [["d", "hush"], ["name", "welcome-everyone"], ["private"]]
            ),
        ], phase: .backfill)

        // The archived duplicate falls through to the live one; the only
        // `welcome-everyone` on this relay is unjoinable, so the name resolves to nothing
        // rather than to it.
        #expect(
            try await store.starterChannelIDs(named: ["general", "welcome-everyone"]) == ["live-general"]
        )
    }

    @Test("names resolve in the order asked, and a name the relay has nothing for is skipped")
    func resolutionOrderAndMisses() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        try await store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "w"], ["name", "welcome-everyone"]]),
            relay.event(.groupMetadata, "", tags: [["d", "g"], ["name", "General"]]),
        ], phase: .backfill)

        // Case-insensitive: the relay stores a name as typed, and `General` is the same
        // channel a community bootstrap meant by `general`.
        #expect(
            try await store.starterChannelIDs(named: SyncEngine.starterChannelNames) == ["g", "w"]
        )
        #expect(try await store.starterChannelIDs(named: ["nowhere"]).isEmpty)
    }

    // MARK: - The seeding mark

    @Test("the seeding mark is per identity")
    func seedingMarkIsPerIdentity() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let first = try Fixture()
        let second = try Fixture()

        #expect(try await store.hasSeededStarterChannels(identity: first.pubkey) == false)
        try await store.recordStarterChannelsSeeded(identity: first.pubkey)
        #expect(try await store.hasSeededStarterChannels(identity: first.pubkey))
        // Two identities on one device have separate rosters; one being seeded says
        // nothing about the other.
        #expect(try await store.hasSeededStarterChannels(identity: second.pubkey) == false)
    }
}
