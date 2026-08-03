@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// A direct message with more than one other person in it.
///
/// The rule it turns on: a group DM and a private channel are the *same shape* from the
/// client's side — several people, no name anybody chose — so the relay's own
/// `["t","dm"]` is what separates them, and nothing here may infer one from a roster
/// alone. Everything else follows from that: which heading it files under, what it is
/// called, and what is drawn where a face would be.
@Suite("Group direct messages", .timeLimit(.minutes(1)))
struct GroupDirectMessageTests {
    private static func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    // Internal rather than private only so ``GroupDirectMessageHintTests`` — the same suite,
    // in the file beside this one — builds its resolvers the same way this one does.
    let me = key(0x11)
    let ada = key(0x22)
    let bo = key(0x33)
    let cy = key(0x44)
    private let nameless = key(0x55)

    func names(
        rosters: [String: Set<String>],
        channels: [ChannelListRow],
        entities: [DirectoryEntity]? = nil,
        selfPubkey: String? = nil
    ) -> EntityNames {
        let people = entities ?? [
            DirectoryEntity(pubkey: me, profileName: "Me"),
            DirectoryEntity(pubkey: ada, profileName: "Ada"),
            DirectoryEntity(pubkey: bo, profileName: "Bo"),
            DirectoryEntity(pubkey: cy, profileName: "Cy"),
        ]
        return EntityNames(
            snapshot: DirectorySnapshot(
                entities: Dictionary(uniqueKeysWithValues: people.map { ($0.pubkey, $0) }),
                memberPubkeysByChannel: rosters
            ),
            channels: channels,
            selfPubkey: selfPubkey ?? me
        )
    }

    func groupRow(
        _ id: String = "gdm",
        name: String? = "Group DM (4)"
    ) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: name,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil,
            channelType: "dm"
        )
    }

    // MARK: - Classification

    @Test("a DM the relay names with more than two people in it is a group conversation")
    func groupDerivation() {
        let resolver = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
        let conversation = resolver.conversation(for: "gdm")

        #expect(conversation.kind == .group)
        #expect(conversation.isDirect)
        // No peer, and therefore no face, no presence dot, and no profile: a group DM is a
        // direct message with nobody in particular on the other end.
        #expect(!conversation.isOneToOne)
        #expect(conversation.peer == nil)
        #expect(conversation.picture == nil)
        #expect(conversation.memberCount == 4)
        // Slack's own line: the people, not the relay's placeholder.
        #expect(conversation.title == "Ada, Bo, Cy")
    }

    @Test("a private channel of the same size is still a channel")
    func privateChannelIsNotAGroup() {
        let row = ChannelListRow(
            id: "room",
            name: "launch",
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil,
            channelType: "stream"
        )
        let resolver = names(rosters: ["room": [me, ada, bo, cy]], channels: [row])

        #expect(resolver.conversation(for: "room").kind == .channel)
        #expect(resolver.conversation(for: "room").title == "launch")
    }

    @Test("a DM of two is still a one-to-one, whatever the relay calls the channel")
    func twoMemberDirectMessageIsUnchanged() {
        let resolver = names(rosters: ["dm": [me, ada]], channels: [groupRow("dm", name: "DM")])
        let conversation = resolver.conversation(for: "dm")

        #expect(conversation.kind == .direct)
        #expect(conversation.isOneToOne)
        #expect(conversation.title == "Ada")
    }

    /// The roster and the metadata arrive independently, and the group rule is the roster's
    /// question. Before it lands there is nobody to list, so the conversation is whatever it
    /// can honestly be — never a list of names it does not have.
    @Test("a group DM whose roster has not landed does not invent one")
    func rosterlessGroupFallsBack() {
        let resolver = names(rosters: [:], channels: [groupRow()])
        let conversation = resolver.conversation(for: "gdm")

        #expect(conversation.kind == .channel)
        #expect(conversation.memberCount == 0)
    }

    // MARK: - Naming

    @Test("a name somebody chose beats the people in the room")
    func chosenNameWins() {
        let resolver = names(
            rosters: ["gdm": [me, ada, bo, cy]],
            channels: [groupRow(name: "Launch crew")]
        )
        #expect(resolver.conversation(for: "gdm").title == "Launch crew")
    }

    /// A `Set` has no order, so without a total one the same conversation would list its
    /// people differently from pass to pass — and the sidebar sorts DMs by their rendered
    /// title, so the row would move as well as re-read.
    @Test("the people are listed in one order, whatever order the roster arrives in")
    func nameOrderIsTotal() {
        let forwards = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
        let backwards = names(rosters: ["gdm": [cy, bo, ada, me]], channels: [groupRow()])

        #expect(forwards.conversation(for: "gdm").title == "Ada, Bo, Cy")
        #expect(backwards.conversation(for: "gdm").title == "Ada, Bo, Cy")
    }

    @Test("somebody with no name at all is listed by their short identifier, never a raw key")
    func namelessMemberIsShortened() {
        let resolver = names(
            rosters: ["gdm": [me, ada, nameless]],
            channels: [groupRow(name: "Group DM (3)")],
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: ada, profileName: "Ada"),
                DirectoryEntity(pubkey: nameless),
            ]
        )

        let title = resolver.conversation(for: "gdm").title
        #expect(title.hasPrefix("Ada, npub1"))
        #expect(title.contains("…"))
        #expect(!title.contains(nameless))
    }

    @Test("recognises the relay's placeholder names and leaves real ones alone")
    func genericNameDetection() {
        for placeholder in [
            "", "   ", "DM", "dm", "Direct message", "Direct Messages",
            "Group DM", "group dm", "Group DM (3)", "GROUP DM(12)", "Group DM  (4)",
        ] {
            #expect(
                EntityNames.isGenericDirectMessageName(placeholder),
                "\(placeholder) should read as the relay's own placeholder"
            )
        }
        for chosen in [
            "Launch crew", "DMs", "Group DMs", "Group DM (x)", "Group DM ()",
            "Group DM (3) and friends", "dm-team",
        ] {
            #expect(
                !EntityNames.isGenericDirectMessageName(chosen),
                "\(chosen) is a name somebody chose"
            )
        }
        #expect(EntityNames.isGenericDirectMessageName(nil))
    }

    // MARK: - Where it goes and what marks it

    @Test("a group DM files with the direct messages, and counts every message as unread")
    func filesUnderDirectMessages() {
        #expect(SidebarSection.section(for: .group) == .directMessages)
        #expect(SidebarSection.directMessages.title == "DMs")
        // Nobody is in a group DM for the traffic, so — like a one-to-one — every message
        // in it is addressed to them, not only the ones that spell their name.
        #expect(
            UnreadIndicator.resolve(unreadCount: 3, mentionCount: 0, isDirect: true)
                == .directUnread(3)
        )
    }

    @Test("the header marks a group DM with how many people are in it")
    func headerMarkIsTheCount() {
        let resolver = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
        let conversation = resolver.conversation(for: "gdm")

        #expect(ConversationTitleBar.mark(for: conversation) == .count(4))
        // Costed as a glyph, not as a face: it is a digit or two, and charging it the
        // avatar's width is what takes a long heading into the overflow menu.
        #expect(
            ConversationTitleBar.reservedChrome(for: .count(4))
                == ConversationTitleBar.reservedChrome(for: .symbol("number"))
        )
    }

    @Test("the count on the tile is the roster size, bounded so it cannot widen the tile")
    func countTextIsBounded() {
        #expect(ConversationMark.countText(4) == "4")
        #expect(ConversationMark.countText(12) == "12")
        #expect(ConversationMark.countText(99) == "99")
        #expect(ConversationMark.countText(100) == "99+")
    }

    @Test("a drawn count is spoken, on the sidebar row and on the draft row")
    func countIsSpoken() {
        let resolver = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
        let group = resolver.conversation(for: "gdm")
        #expect(ChannelRowView.peopleDescription(group) == "4 people")

        // A channel's roster is not what its row is about, and a one-to-one's is two by
        // definition — so neither says it.
        let dm = names(rosters: ["dm": [me, ada]], channels: [groupRow("dm", name: "DM")])
            .conversation(for: "dm")
        #expect(ChannelRowView.peopleDescription(dm) == nil)
    }

    // MARK: - Drafts

    @Test("a draft in a group DM is titled by its people, on up to two lines")
    func draftRowTitle() {
        let resolver = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
        let group = resolver.conversation(for: "gdm")
        let draft = ComposerDraftSummary(
            channelID: "gdm",
            rootID: nil,
            snippet: "half a thought",
            updatedAt: 1_000
        )

        #expect(DraftRowText.title(for: draft, in: group) == "Ada, Bo, Cy")
        // A list of names needs a second line; a name somebody chose to be a name does not,
        // and giving every row two would leave the list unevenly tall for nothing.
        #expect(DraftRow.titleLines(for: group) == 2)

        let dm = names(rosters: ["dm": [me, ada]], channels: [groupRow("dm", name: "DM")])
            .conversation(for: "dm")
        #expect(DraftRow.titleLines(for: dm) == 1)
    }

    /// A thread inside a *channel* swaps the `#` for the thread's mark, because the two
    /// destinations sit next to each other on this screen. A thread inside a direct message
    /// of either size keeps the mark of the people it is with.
    @Test("a thread inside a group DM keeps the count rather than the thread glyph")
    func threadInGroupKeepsTheCount() {
        let resolver = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
        let group = resolver.conversation(for: "gdm")
        let reply = ComposerDraftSummary(
            channelID: "gdm",
            rootID: "root-1",
            snippet: "later",
            updatedAt: 1_000
        )

        #expect(DraftRowMark.symbol(for: reply, in: group) == nil)
        #expect(DraftRowText.title(for: reply, in: group) == "Thread in Ada, Bo, Cy")
    }
}
