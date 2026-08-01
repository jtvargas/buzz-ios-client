import Foundation
@testable import Hive
import Testing

/// The record and the rules over it: what counts as the same relay, and what the list does
/// when communities are added, removed, renamed and switched between.
@Suite struct CommunityRecordTests {
    @Test func canonicalisesTheRelayItIsComparedOn() {
        #expect(Community.relayIdentity(of: "wss://Homelab.ts.net/") == "wss://homelab.ts.net")
        #expect(Community.relayIdentity(of: "wss://homelab.ts.net") == "wss://homelab.ts.net")
        #expect(Community.relayIdentity(of: "ws://host:3004") == "ws://host:3004")
        // A port is part of the relay: two ports on one host are two relays.
        #expect(Community.relayIdentity(of: "ws://host:3004") != Community.relayIdentity(of: "ws://host:3005"))
    }

    @Test func refusesAnythingThatIsNotARelayURL() {
        #expect(Community.relayIdentity(of: "http://host") == nil)
        #expect(Community.relayIdentity(of: "garbage") == nil)
        // Two unparseable strings are not "the same relay" — nothing matches nothing.
        #expect(!Community.new(relayURLString: "garbage").isSameRelay(as: "garbage"))
    }

    @Test func aNewCommunityOwnsStorageNoOtherCommunityNames() {
        let first = Community.new(relayURLString: "wss://a.example")
        let second = Community.new(relayURLString: "wss://b.example")
        #expect(first.keychainAccount != second.keychainAccount)
        #expect(first.storeFilename != second.storeFilename)
        #expect(first.keychainAccount != Community.legacyKeychainAccount)
        #expect(first.storeFilename != Community.legacyStoreFilename)
    }

    @Test func theAdoptedInstallKeepsTheStorageItAlreadyHas() {
        let adopted = Community.adoptingLegacyInstall(
            relayURLString: "wss://homelab.tail4bc643.ts.net",
            ownerPubkeyHex: "abc"
        )
        #expect(adopted.keychainAccount == Community.legacyKeychainAccount)
        #expect(adopted.storeFilename == Community.legacyStoreFilename)
        #expect(adopted.ownerPubkeyHex == "abc")
        // Named the way every Buzz client names it — the host, lowercased.
        #expect(adopted.name == "homelab")
    }
}

@Suite struct CommunityDirectoryTests {
    /// A directory holding one community per relay, in the order given.
    private func directory(_ relays: String...) -> CommunityDirectory {
        var directory = CommunityDirectory()
        for relay in relays { directory.add(Community.new(relayURLString: relay)) }
        return directory
    }

    @Test func theFirstCommunityAddedIsTheOneBeingRead() {
        let directory = directory("wss://a.example", "wss://b.example")
        #expect(directory.activeID == directory.communities[0].id)
        #expect(directory.active?.relayURLString == "wss://a.example")
    }

    @Test func oneRelayCannotBecomeTwoCommunities() {
        var directory = directory("wss://a.example")
        let original = directory.communities[0]
        let id = directory.add(Community.new(relayURLString: "wss://A.example/", ownerPubkeyHex: "newowner"))
        #expect(directory.communities.count == 1)
        #expect(id == original.id)
        // The incoming identity is taken; the storage the history is already in is not.
        #expect(directory.communities[0].ownerPubkeyHex == "newowner")
        #expect(directory.communities[0].storeFilename == original.storeFilename)
    }

    @Test func aRenameSurvivesReAddingTheSameRelay() {
        var directory = directory("wss://a.example")
        directory.rename(directory.communities[0].id, to: "Work")
        directory.add(Community.new(relayURLString: "wss://a.example"))
        #expect(directory.communities.map(\.name) == ["Work"])
    }

    @Test func aDanglingActiveIDIsRepairedOnTheWayIn() {
        let loaded = directory("wss://a.example", "wss://b.example")
        let repaired = CommunityDirectory(communities: loaded.communities, activeID: UUID())
        #expect(repaired.activeID == loaded.communities[0].id)
        let honoured = CommunityDirectory(communities: loaded.communities, activeID: loaded.communities[1].id)
        #expect(honoured.activeID == loaded.communities[1].id)
    }

    @Test func removingTheActiveCommunityWalksForwards() {
        var directory = directory("wss://a.example", "wss://b.example", "wss://c.example")
        let ids = directory.communities.map(\.id)
        directory.setActive(ids[1])
        #expect(directory.remove(ids[1])?.id == ids[1])
        #expect(directory.activeID == ids[2])
    }

    @Test func removingTheLastOneLeavesNothingActive() {
        var directory = directory("wss://a.example")
        #expect(directory.remove(directory.communities[0].id) != nil)
        #expect(directory.isEmpty)
        #expect(directory.active == nil)
        #expect(directory.activeID == nil)
    }

    @Test func removingSomethingElseDoesNotMoveTheReader() {
        var directory = directory("wss://a.example", "wss://b.example")
        let ids = directory.communities.map(\.id)
        directory.remove(ids[1])
        #expect(directory.activeID == ids[0])
    }

    @Test func aStaleRowCannotPointTheAppAtNothing() {
        var directory = directory("wss://a.example")
        let first = directory.communities[0].id
        directory.setActive(UUID())
        #expect(directory.activeID == first)
    }

    @Test func renamingTakesOnlyANameFitForATitleBar() {
        var directory = directory("wss://a.example")
        let id = directory.communities[0].id
        let original = directory.communities[0].name
        directory.rename(id, to: "   ")
        #expect(directory.communities[0].name == original)
        directory.rename(id, to: "  Work  ")
        #expect(directory.communities[0].name == "Work")
    }

    @Test func findsTheCommunityAlreadyOnARelay() {
        let directory = directory("wss://a.example", "wss://b.example")
        #expect(directory.community(forRelay: "wss://B.example")?.id == directory.communities[1].id)
        #expect(directory.community(forRelay: "wss://c.example") == nil)
    }
}
