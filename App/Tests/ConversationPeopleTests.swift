@testable import BuzzKit
@testable import Hive
import Testing

/// Who is in a conversation — the `person.3.fill` sheet's two sources — and what the two
/// trailing buttons cost the heading beside them.
@Suite("Conversation people")
struct ConversationPeopleTests {
    // MARK: - A thread's participants

    @Test("a thread's people are whoever spoke, in the order they first did")
    func participantsInFirstAppearanceOrder() {
        let rows = [
            makeRow(id: "root", at: 100, pubkey: "ana"),
            makeRow(id: "r1", at: 200, pubkey: "cal"),
            makeRow(id: "r2", at: 300, pubkey: "ben"),
            makeRow(id: "r3", at: 400, pubkey: "cal"),
        ]
        let people = ConversationPerson.threadParticipants(in: rows, root: "root")
        // Not alphabetical: a thread is a sequence, and sorting by name would file the
        // person who opened it wherever the alphabet happens to.
        #expect(people.map(\.pubkey) == ["ana", "cal", "ben"])
    }

    @Test("the opener is named as the opener, and their opening message is not a reply")
    func openerIsNotCountedAsAReplier() {
        let rows = [
            makeRow(id: "root", at: 100, pubkey: "ana"),
            makeRow(id: "r1", at: 200, pubkey: "ben"),
        ]
        let people = ConversationPerson.threadParticipants(in: rows, root: "root")
        #expect(people.first?.detail == "Opened the thread")
        #expect(people.last?.detail == "1 reply")
    }

    @Test("an opener who also replied gets both facts")
    func openerWhoAlsoReplied() {
        let rows = [
            makeRow(id: "root", at: 100, pubkey: "ana"),
            makeRow(id: "r1", at: 200, pubkey: "ana"),
            makeRow(id: "r2", at: 300, pubkey: "ana"),
        ]
        let people = ConversationPerson.threadParticipants(in: rows, root: "root")
        #expect(people.count == 1)
        #expect(people.first?.detail == "Opened the thread · 2 replies")
    }

    @Test("a deleted message still puts its author in the thread")
    func deletedMessageStillCounts() {
        // The reader sees "message deleted" sitting in the thread, so the person who left
        // it is in the thread. Dropping them would make the sheet disagree with the rows.
        var rows = [makeRow(id: "root", at: 100, pubkey: "ana")]
        rows.append(TimelineRow(
            id: "r1",
            pubkey: "ben",
            createdAt: 200,
            content: "",
            isEdited: false,
            isDeleted: true,
            richContent: nil,
            delivery: .sent,
            authorName: nil,
            authorPicture: nil,
            parentID: "root",
            rootID: "root",
            replyCount: 0,
            lastReplyAt: nil
        ))
        #expect(ConversationPerson.threadParticipants(in: rows, root: "root").map(\.pubkey) == ["ana", "ben"])
    }

    @Test("a thread whose opener has not arrived still lists its repliers")
    func openerMissing() {
        // The thread fetch can land replies before the opener. Nobody is "the opener"
        // then, and the honest answer is a plain reply count rather than a guess.
        let rows = [makeRow(id: "r1", at: 200, pubkey: "ben")]
        let people = ConversationPerson.threadParticipants(in: rows, root: "root")
        #expect(people.map(\.pubkey) == ["ben"])
        #expect(people.first?.detail == "1 reply")
    }

    // MARK: - A channel's roster

    @Test("a member's roster role becomes their second line, and no role means no line")
    func roleIsTheDetailLine() {
        let admin = ConversationPerson(member: MemberProfile(pubkey: "ana", role: "admin"))
        #expect(admin.detail == "Admin")
        #expect(ConversationPerson(member: MemberProfile(pubkey: "ben")).detail == nil)
        // Not an empty string: a row that reserves space for a line it has nothing to put
        // in reads as a rendering bug.
        #expect(ConversationPerson(member: MemberProfile(pubkey: "cal", role: "  ")).detail == nil)
    }

    @Test("the count says what it is counting")
    func countLabelIsAPhrase() {
        #expect(ConversationPeopleList.countLabel(1) == "1 person")
        #expect(ConversationPeopleList.countLabel(12) == "12 people")
    }

    // MARK: - What the trailing buttons cost the heading

    @Test("each trailing button is charged against the name beside it")
    func trailingButtonsAreCharged() {
        // A toolbar item that does not fit is not truncated — it is moved into the `…`
        // overflow menu, so the whole heading disappears. Two 44pt buttons and the seam
        // between them are 96pt of a phone's bar; absorbing that rather than charging it
        // is how a long channel name would take the heading with it.
        #expect(ConversationTitleBar.trailingReserve(0) == 0)
        #expect(ConversationTitleBar.trailingReserve(1) == 44)
        #expect(ConversationTitleBar.trailingReserve(2) == 96)

        // Charged in full where there is room to charge it — a landscape iPad, where the
        // floor is nowhere near binding.
        let hash = ConversationTitleBar.Mark.symbol("number")
        let bare = ConversationTitleBar.labelWidth(forSurfaceWidth: 1000, mark: hash)
        let withBoth = ConversationTitleBar.labelWidth(forSurfaceWidth: 1000, mark: hash, trailingActions: 2)
        #expect(bare - withBoth == 96)
    }

    @Test("on a phone the floor absorbs the charge, which is why a test drives the real bar")
    func theFloorBindsOnEveryPhone() {
        // 440 − 180 − 96 = 164, under the 190 floor. So on every iPhone in portrait the
        // name gets exactly the floor whether one button sits beside it or two, and this
        // arithmetic can no longer answer the question it exists for. That is what
        // `ConversationTitleBarTests` is for: it opens the real bar with a 76-character
        // name and reads whether the heading survived. Left asserted rather than left
        // implicit, so that a future change to either constant shows up as this test
        // failing and sends the reader to the one that measures.
        let hash = ConversationTitleBar.Mark.symbol("number")
        for width in [375.0, 402.0, 440.0] {
            #expect(ConversationTitleBar.labelWidth(forSurfaceWidth: width, mark: hash, trailingActions: 2) == 190)
        }
    }

    @Test("a surface with no trailing buttons keeps the width the measured cliff was fitted to")
    func noTrailingButtonsIsUnchanged() {
        // The 402pt/245pt cliff in `MessageSurfaceTests` was measured with nothing at the
        // trailing edge. Those screens — the sidebar, the Activity tab — must still get
        // exactly that, or the reserve stops describing anything that was measured.
        let hash = ConversationTitleBar.Mark.symbol("number")
        #expect(ConversationTitleBar.labelWidth(forSurfaceWidth: 402, mark: hash, trailingActions: 0)
            == ConversationTitleBar.labelWidth(forSurfaceWidth: 402, mark: hash))
    }

    @Test("the floor still holds once both buttons are charged")
    func floorHoldsWithButtons() {
        // A heading of two characters would be worse than one that truncates, so the
        // column floors rather than going to nothing on the narrowest phone.
        let hash = ConversationTitleBar.Mark.symbol("number")
        #expect(ConversationTitleBar.labelWidth(forSurfaceWidth: 375, mark: hash, trailingActions: 2) >= 190)
    }

    // MARK: - What mute does to a row

    @Test("a muted conversation reads as caught up, badge and mention alike")
    func muteSuppressesTheBadge() {
        // Hive has no push notifications, so the badge is the whole of what mute can mean
        // here — a toggle that only remembered itself would be worse than no toggle.
        func resolve(mentions: Int, isDirect: Bool, isMuted: Bool) -> UnreadIndicator {
            UnreadIndicator.resolve(
                unreadCount: 5,
                mentionCount: mentions,
                isDirect: isDirect,
                isMuted: isMuted
            )
        }
        #expect(resolve(mentions: 0, isDirect: false, isMuted: true) == .caughtUp)
        #expect(resolve(mentions: 2, isDirect: false, isMuted: true) == .caughtUp)
        #expect(resolve(mentions: 0, isDirect: true, isMuted: true) == .caughtUp)
        // Unmuted, the same row is exactly what it was before mute existed.
        #expect(resolve(mentions: 2, isDirect: false, isMuted: false) == .mention(2))
        #expect(resolve(mentions: 0, isDirect: false, isMuted: false) == .unread)
    }
}
