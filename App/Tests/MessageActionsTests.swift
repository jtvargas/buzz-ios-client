import BuzzKit
@testable import Hive
import Testing

/// The message actions sheet's own logic, which is two things: what a chosen emoji means on
/// a message that may already carry it, and which message the sheet is presented for.
///
/// Deliberately not here: whether the long press *fires*, what the sheet looks like, and
/// whether it rests at the medium detent. Those are a gesture, a material and a
/// presentation, and a unit test can only restate the constants they are built from — they
/// are on the owner's device pass, the same split ``MessageSurfaceTests`` documents.
@Suite("Message actions", .timeLimit(.minutes(1)))
struct MessageActionsTests {
    private func group(
        _ emoji: String,
        count: Int = 1,
        mine: Bool = false,
        id: String? = nil
    ) -> ReactionGroup {
        ReactionGroup(emoji: emoji, count: count, reactedBySelf: mine, selfReactionID: id)
    }

    // MARK: - What a chosen emoji means

    @Test("an emoji nobody has sent is added")
    func unseenEmojiIsAdded() {
        #expect(ReactionPalette.choice(for: "✅", in: []) == .add("✅"))
        #expect(ReactionPalette.choice(for: "✅", in: [group("👀")]) == .add("✅"))
    }

    @Test("an emoji the reader has already sent is toggled, not sent again")
    func ownEmojiIsToggled() {
        // The defect this exists for: a second `react` would queue a second identical
        // kind-7, and the reader would be counted twice on their own reaction.
        let mine = group("👍🏻", mine: true, id: "REACTION")
        #expect(ReactionPalette.choice(for: "👍🏻", in: [mine]) == .toggle(mine))
    }

    @Test("an emoji somebody else has sent joins their chip rather than starting a new one")
    func peerEmojiIsToggled() {
        let theirs = group("❤️", count: 3)
        #expect(ReactionPalette.choice(for: "❤️", in: [theirs]) == .toggle(theirs))
    }

    @Test("the choice matches on the exact emoji string, skin tone included")
    func skinToneIsNotTheSameReaction() {
        // Why the palette carries 👍🏻 and the app's own chips have to carry the same
        // characters: these are two different reactions everywhere below this line, and a
        // palette that disagreed with itself would put two thumbs on one message.
        #expect(ReactionPalette.choice(for: "👍🏻", in: [group("👍")]) == .add("👍🏻"))
    }

    // MARK: - The palette itself

    @Test("the quick palette is the owner's five, in order, with no repeats")
    func paletteIsTheOwnersFive() {
        #expect(ReactionPalette.common == ["🤔", "👀", "👍🏻", "❤️", "✅"])
        // A repeat would be two targets in the row that can never both be lit, because a
        // reaction groups on its emoji.
        #expect(Set(ReactionPalette.common).count == ReactionPalette.common.count)
    }

    // MARK: - Which message the sheet is for

    @Test("a target is identified by its message, so a second long press re-presents")
    func targetIdentityIsTheMessage() {
        // `sheet(item:)` keys off this. Were the id constant, long-pressing a second message
        // while the first sheet was still animating away would show the first one's actions.
        let first = MessageActionTarget(
            row: row(id: "A"),
            isOwn: false,
            channelID: "CHANNEL",
            threadRootID: nil
        )
        let second = MessageActionTarget(
            row: row(id: "B"),
            isOwn: false,
            channelID: "CHANNEL",
            threadRootID: nil
        )
        #expect(first.id == "A")
        #expect(second.id == "B")
        #expect(first != second)
    }

    private func row(id: String, delivery: Delivery = .sent) -> TimelineRow {
        TimelineRow(
            id: id,
            pubkey: "author",
            createdAt: 1_000,
            content: "hello",
            isEdited: false,
            isDeleted: false,
            richContent: nil,
            delivery: delivery,
            authorName: nil,
            authorPicture: nil,
            parentID: nil,
            rootID: nil,
            replyCount: 0,
            lastReplyAt: nil
        )
    }
}
