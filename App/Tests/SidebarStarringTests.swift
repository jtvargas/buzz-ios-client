@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

// Part 6's starring: which heading a starred conversation is filed under, and that the
// star itself survives a launch. An extension of ``SidebarSectionsTests`` rather than its
// own suite, so it builds its rows through exactly the fixtures the classification and
// ordering tests use — a star is not a different kind of sidebar row.

// MARK: - Starring

extension SidebarSectionsTests {
    @Test("a starred conversation moves into Starred rather than appearing twice")
    func starredMovesOutOfItsKindsSection() {
        let rows = [
            channel("general", name: "General"),
            channel("random", name: "Random"),
            channel("dm-peer", name: "dm"),
        ]
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: peer, profileName: "Ada"),
            ],
            rosters: ["general": [me, peer, other], "random": [me, peer, other], "dm-peer": [me, peer]],
            channels: rows,
            selfPubkey: me
        )

        // A channel and a DM starred together: both land under one heading, and neither
        // is left behind under its own kind. `dm-peer` was the only direct message, so
        // DMs is left standing and empty — the one heading that does that, because a
        // person with no conversations needs telling, and a starred DM has still left
        // the section it was filed under.
        let content = build(rows, names: resolver, starred: ["general", "dm-peer"])
        #expect(content.sections.map(\.section) == [.starred, .channels, .directMessages])
        #expect(content.sections[2].rows.isEmpty)
        #expect(Set(content.sections[0].rows.map(\.id)) == ["general", "dm-peer"])
        #expect(content.sections[1].rows.map(\.id) == ["random"])

        // Every row knows its own star, so the menu's label and the heading agree.
        #expect(content.sections[0].rows.map(\.isStarred) == [true, true])
        #expect(content.sections[1].rows.map(\.isStarred) == [false])
    }

    @Test("Starred is absent when nothing is starred, and starring the last row empties a section")
    func starredSectionAppearsAndDisappears() {
        let rows = [channel("general", name: "General"), channel("random", name: "Random")]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            rosters: ["general": [me, peer, other], "random": [me, peer, other]],
            channels: rows,
            selfPubkey: me
        )

        #expect(build(rows, names: resolver).sections.map(\.section) == [.channels, .directMessages])
        // Starring everything leaves no Channels heading at all — an empty section is
        // absent, not empty, for every heading except DMs.
        let all = build(rows, names: resolver, starred: ["general", "random"])
        #expect(all.sections.map(\.section) == [.starred, .directMessages])
        #expect(all.sections[0].rows.map(\.id) == ["general", "random"])
    }

    @Test("a star id that matches nothing is ignored rather than inventing a section")
    func unknownStarIsIgnored() {
        let rows = [channel("general", name: "General")]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            rosters: ["general": [me, peer, other]],
            channels: rows,
            selfPubkey: me
        )
        // A conversation starred on this device and since left, or not yet synced.
        let content = build(rows, names: resolver, starred: ["gone"])
        #expect(content.sections.map(\.section) == [.channels, .directMessages])
    }

    @Test("stars persist under a pinned defaults key")
    @MainActor
    func starsPersist() throws {
        let suiteName = "starred-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let starred = StarredConversations(defaults: defaults)
        #expect(starred.ids.isEmpty)
        #expect(!starred.isStarred("general"))

        starred.toggle("general")
        #expect(starred.isStarred("general"))
        // Written through immediately: there is no later moment at which a star is
        // committed, so a launch after the swipe must find it.
        #expect(defaults.stringArray(forKey: StarredConversations.storageKey) == ["general"])
        #expect(StarredConversations(defaults: defaults).ids == ["general"])

        starred.toggle("general")
        #expect(!starred.isStarred("general"))
        #expect(StarredConversations(defaults: defaults).ids.isEmpty)

        // An empty id is not a conversation; storing one would put a row nothing matches
        // into the Starred heading forever.
        starred.toggle("")
        #expect(starred.ids.isEmpty)

        // Pinned: renaming it silently discards every star an existing install has set.
        #expect(StarredConversations.storageKey == "sidebar.starred.conversations")
    }
}

// MARK: - Ordering

extension SidebarSectionsTests {
    @Test("orders newest first inside a section, messageless last, then by rendered title")
    func ordering() {
        let rows = [
            channel("zulu", name: "Zulu", lastMessageAt: nil),
            channel("alpha", name: "Alpha", lastMessageAt: nil),
            channel("older", name: "Older", lastMessageAt: 1_000),
            channel("newer", name: "Newer", lastMessageAt: 2_000),
        ]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            channels: rows,
            selfPubkey: me
        )

        let ordered = build(rows, names: resolver).sections[0].rows.map(\.id)
        #expect(ordered == ["newer", "older", "alpha", "zulu"])
    }

    @Test("a DM sorts on the peer's name, not the group's, and ties break on id")
    func orderingUsesRenderedTitle() {
        let rows = [
            channel("dm-b", name: "zzz-group"),
            channel("dm-a", name: "aaa-group"),
        ]
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: peer, profileName: "Ada"),
                DirectoryEntity(pubkey: agent, profileName: "Zoe"),
            ],
            rosters: ["dm-b": [me, peer], "dm-a": [me, agent]],
            channels: rows,
            selfPubkey: me
        )

        // `dm-b` is named "zzz-group" but is a DM with Ada, so it sorts first.
        #expect(build(rows, names: resolver).sections[0].rows.map(\.title) == ["Ada", "Zoe"])

        // Same timestamp and same rendered title: the group id is the last resort, so
        // the order is total and does not flicker between reads.
        let ambiguous = [
            channel("b-id", name: "Same", lastMessageAt: 5),
            channel("a-id", name: "Same", lastMessageAt: 5),
        ]
        let plain = names(entities: [], channels: ambiguous)
        #expect(build(ambiguous, names: plain).sections[0].rows.map(\.id) == ["a-id", "b-id"])
    }
}
