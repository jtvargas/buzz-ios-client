@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// Which messages stack under which — the rule that turns a column of identical rows into
/// blocks of one person speaking, and the reason a reader sees one avatar per block
/// instead of one per message.
///
/// The rule lives in ``ConversationGrouping`` rather than in the row, so it is asserted
/// here as data: `groupedShape` marks every continuation with a leading `+`, and each test
/// below is one way a block is allowed to end.
@Suite("Message grouping", .timeLimit(.minutes(1)))
struct ConversationGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Well inside one day, so nothing below is a day-separator test by accident.
    private let noon: Int64 = 1_700_000_000

    private func items(_ rows: [TimelineRow]) -> [ConversationItem] {
        ConversationGrouping.items(for: rows, calendar: calendar)
    }

    @Test("consecutive messages from one author stack under the first")
    func consecutiveMessagesGroup() {
        let grouped = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeRow(id: "2", at: noon + 30, content: "two"),
            makeRow(id: "3", at: noon + 60, content: "three"),
        ])

        // One block: the first message names its author, the other two stack under it.
        #expect(groupedShape(grouped) == ["day", "one", "+two", "+three"])
    }

    @Test("a different author always starts a new block")
    func differentAuthorBreaksTheBlock() {
        let grouped = items([
            makeRow(id: "1", at: noon, content: "one", pubkey: "ada"),
            makeRow(id: "2", at: noon + 1, content: "two", pubkey: "grace"),
            makeRow(id: "3", at: noon + 2, content: "three", pubkey: "ada"),
        ])

        // One second apart and still three blocks: identity beats proximity.
        #expect(groupedShape(grouped) == ["day", "one", "two", "three"])
    }

    @Test("the block survives a five-minute pause and ends a second later")
    func theWindowIsFiveMinutes() {
        let window = Int64(ConversationGrouping.groupWindow)
        let grouped = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeRow(id: "2", at: noon + window, content: "two"),
            makeRow(id: "3", at: noon + window * 2 + 1, content: "three"),
        ])

        // Measured from the message directly above, not from the head of the block: "two"
        // is five minutes after "one" and stacks, "three" is five minutes *and a second*
        // after "two" and does not.
        #expect(groupedShape(grouped) == ["day", "one", "+two", "three"])
    }

    @Test("a message that appears to predate the one above it never stacks under it")
    func clockSkewNeverGroups() {
        // Both orderings a relay with a backwards clock can produce, and neither may join
        // a message to one that comes after it.
        let grouped = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeRow(id: "2", at: noon - 10, content: "two"),
        ])

        #expect(groupedShape(grouped) == ["day", "one", "two"])
    }

    @Test("a day separator ends the block even when the two messages are seconds apart")
    func aDaySeparatorEndsTheBlock() {
        // 23:59:30 and 00:00:10 — forty seconds, and a date heading between them, so the
        // message under the heading has to name its author or the heading interrupts a
        // block that then never re-introduces itself.
        let midnight = Int64(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!.timeIntervalSince1970
        )
        let grouped = items([
            makeRow(id: "1", at: midnight - 30, content: "tuesday"),
            makeRow(id: "2", at: midnight + 10, content: "wednesday"),
        ])

        #expect(groupedShape(grouped) == ["day", "tuesday", "day", "wednesday"])
    }

    @Test("a relay notice ends the block, and one this build cannot read does not")
    func aNoticeEndsTheBlock() {
        let member = String(repeating: "b", count: 64)
        let joined = "{\"type\":\"member_joined\",\"actor\":\"\(member)\",\"target\":\"\(member)\"}"

        let interrupted = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeNoticeRow(
                id: "n", at: noon + 1, body: joined,
                notice: .memberJoined(actor: member, target: member)
            ),
            makeRow(id: "2", at: noon + 2, content: "two"),
        ])
        // Something was drawn between them, so "two" names its author again.
        #expect(groupedShape(interrupted) == ["day", "one", "notice", "two"])

        let dropped = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeNoticeRow(id: "n", at: noon + 1, body: "{\"type\":\"ttl_changed\"}", notice: nil),
            makeRow(id: "2", at: noon + 2, content: "two"),
        ])
        // Nothing was drawn, so nothing came between: a notice this build cannot render
        // must not leave a seam in a block a reader would see as unbroken.
        #expect(groupedShape(dropped) == ["day", "one", "+two"])
    }

    @Test("a message carrying a picture always names its author")
    func attachmentsAlwaysNameTheirAuthor() {
        let picture = MessageMedia(url: "https://example.invalid/cat.jpg", kind: .image)
        let grouped = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeRow(id: "2", at: noon + 1, content: "two", media: [picture]),
            makeRow(id: "3", at: noon + 2, content: "three"),
        ])

        // The reference client's rule (`buzz/mobile`, `message_list.dart`): a picture is
        // what a reader scrolls back to find, so it never hangs unattributed inside a
        // block. The plain message after it stacks under the picture as usual.
        #expect(groupedShape(grouped) == ["day", "one", "two", "+three"])
    }

    @Test("a reply never stacks under an ordinary message, and stacks under a reply")
    func repliesOnlyGroupWithReplies() {
        let grouped = items([
            makeRow(id: "1", at: noon, content: "one"),
            makeRow(id: "2", at: noon + 1, content: "two", parentID: "1"),
            makeRow(id: "3", at: noon + 2, content: "three", parentID: "1"),
        ])

        // The header carries the glyph that marks a message as a reply, so a reply
        // stacking under its author's own ordinary message would lose the only mark that
        // says so. Two replies agree about it and stack — which is what makes grouping
        // work at all inside a thread, where every row is a reply.
        #expect(groupedShape(grouped) == ["day", "one", "two", "+three"])
    }

    @Test("a continuation says who wrote it by ear, and a message that names its author does not")
    func voiceOverKeepsTheAuthor() {
        // The visual attribution is what grouping drops; the spoken one cannot be, because
        // a reader by ear has no message above to take it from.
        #expect(
            MessageAccessibility.status(author: "Ada", isOnline: false, isEdited: false, delivery: .sent)
                == "From Ada"
        )
        #expect(
            MessageAccessibility.status(author: "Ada", isOnline: true, isEdited: true, delivery: .pending)
                == "From Ada, Online, Edited, Sending"
        )
        #expect(MessageAccessibility.status(isOnline: false, isEdited: false, delivery: .sent).isEmpty)
    }
}
