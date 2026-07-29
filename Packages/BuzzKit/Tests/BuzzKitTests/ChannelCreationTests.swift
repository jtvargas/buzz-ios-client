@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The create-channel wire contract: the name the relay will store, and the tags a
/// kind-9007 event carries.
///
/// Pure, and deliberately so — the round trip is exercised where every other command is,
/// but *what is sent* is a value, and a value is worth pinning: a missing `visibility`
/// tag or a lowercased name is a channel that comes out wrong on every other client
/// reading the same relay, and nothing in an app test would notice.
@Suite("Channel creation", .timeLimit(.minutes(1)))
struct ChannelCreationTests {
    // MARK: - The name

    @Test("A leading hash and surrounding whitespace come off, and nothing else changes")
    func canonicalName() {
        #expect(SyncEngine.canonicalChannelName("#release-notes") == "release-notes")
        #expect(SyncEngine.canonicalChannelName("  #release-notes  ") == "release-notes")
        #expect(SyncEngine.canonicalChannelName("release-notes\n") == "release-notes")
        // Not slugified: the relay stores what was typed, so a name made on the phone
        // reads the same on Desktop.
        #expect(SyncEngine.canonicalChannelName("Release Notes") == "Release Notes")
        #expect(SyncEngine.canonicalChannelName("Q3 Planning") == "Q3 Planning")
        // An interior hash is part of the name; only the leading run is a prefix.
        #expect(SyncEngine.canonicalChannelName("c#-corner") == "c#-corner")
        #expect(SyncEngine.canonicalChannelName("##double") == "double")
    }

    @Test("A name that is only a hash or only whitespace canonicalises to nothing")
    func emptyNames() {
        #expect(SyncEngine.canonicalChannelName("").isEmpty)
        #expect(SyncEngine.canonicalChannelName("#").isEmpty)
        #expect(SyncEngine.canonicalChannelName("   ").isEmpty)
        #expect(SyncEngine.canonicalChannelName("# ").isEmpty)
    }

    // MARK: - The tags

    @Test("An open channel carries h, name, visibility and channel_type, in that order")
    func openChannelTags() {
        let tags = SyncEngine.channelCreateTags(
            channelID: "6e9f2b0c-6c0a-4a5e-9a4e-2f9b1a7d3c11",
            name: "release-notes",
            about: nil,
            isPrivate: false
        )
        #expect(tags == [
            ["h", "6e9f2b0c-6c0a-4a5e-9a4e-2f9b1a7d3c11"],
            ["name", "release-notes"],
            ["visibility", "open"],
            ["channel_type", "stream"],
        ])
    }

    @Test("Private flips the visibility tag and nothing else")
    func privateChannelTags() {
        let tags = SyncEngine.channelCreateTags(
            channelID: "id",
            name: "hush",
            about: nil,
            isPrivate: true
        )
        #expect(tags.first { $0.first == "visibility" } == ["visibility", "private"])
        #expect(tags.first { $0.first == "channel_type" } == ["channel_type", "stream"])
    }

    @Test("A description becomes an about tag, trimmed")
    func aboutTag() {
        let tags = SyncEngine.channelCreateTags(
            channelID: "id",
            name: "release-notes",
            about: "  What shipped, and when.\n",
            isPrivate: false
        )
        #expect(tags.last == ["about", "What shipped, and when."])
    }

    @Test("No description means no about tag — an empty one is not a description")
    func noAboutTag() {
        for about in [nil, "", "   ", "\n"] as [String?] {
            let tags = SyncEngine.channelCreateTags(
                channelID: "id",
                name: "release-notes",
                about: about,
                isPrivate: false
            )
            #expect(tags.count == 4, "about \(String(describing: about)) should add no tag")
            #expect(!tags.contains { $0.first == "about" })
        }
    }

    @Test("The kind is NIP-29 create-group")
    func kind() {
        #expect(EventKind.groupCreate.rawValue == 9007)
    }
}
