@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// Relay channel notices (kind 40099): decoding the body, writing the sentence, and
/// keeping them out of the message path.
///
/// The three are separate suites because they fail for different reasons. A decode
/// regression is a wire-format change; a sentence regression is grammar; a grouping
/// regression renders JSON at somebody as if they had typed it.
@Suite("System notice decoding", .timeLimit(.minutes(1)))
struct SystemNoticeDecodingTests {
    /// Two well-formed 64-character keys, distinct in their first byte so an assertion
    /// that swapped them would read differently.
    private let jt = String(repeating: "a", count: 64)
    private let sentry = String(repeating: "b", count: 64)

    private func body(_ type: String, actor: String?, target: String?, extra: String? = nil) -> String {
        var fields = ["\"type\":\"\(type)\""]
        if let actor { fields.append("\"actor\":\"\(actor)\"") }
        if let target { fields.append("\"target\":\"\(target)\"") }
        if let extra { fields.append(extra) }
        return "{\(fields.joined(separator: ","))}"
    }

    @Test("a join under your own steam and an add are the same type, told apart by who acted")
    func joinVersusAdd() {
        #expect(
            SystemNotice.parse(body("member_joined", actor: sentry, target: sentry))
                == .memberJoined(actor: sentry, target: sentry)
        )
        #expect(
            SystemNotice.parse(body("member_joined", actor: jt, target: sentry))
                == .memberJoined(actor: jt, target: sentry)
        )
    }

    @Test("a departure names one person, an eviction names two")
    func departureAndEviction() {
        #expect(SystemNotice.parse(body("member_left", actor: sentry, target: nil)) == .memberLeft(actor: sentry))
        #expect(
            SystemNotice.parse(body("member_removed", actor: jt, target: sentry))
                == .memberRemoved(actor: jt, target: sentry)
        )
    }

    @Test("extra fields decode, because a relay that adds one must not break this build")
    func toleratesUnknownFields() {
        let padded = "{\"type\":\"member_left\",\"actor\":\"\(sentry)\",\"reason\":\"idle\",\"seq\":41}"
        #expect(SystemNotice.parse(padded) == .memberLeft(actor: sentry))
    }

    @Test("what happened to the channel itself, not to its roster")
    func channelEvents() {
        #expect(
            SystemNotice.parse(body("topic_changed", actor: jt, target: nil, extra: "\"topic\":\"Ship it\""))
                == .topicChanged(actor: jt, topic: "Ship it")
        )
        #expect(
            SystemNotice.parse(body("purpose_changed", actor: jt, target: nil, extra: "\"purpose\":\"Releases\""))
                == .purposeChanged(actor: jt, purpose: "Releases")
        )
        #expect(SystemNotice.parse(body("channel_created", actor: jt, target: nil)) == .channelCreated(actor: jt))
        #expect(SystemNotice.parse(body("channel_archived", actor: jt, target: nil)) == .channelArchived(actor: jt))
        #expect(
            SystemNotice.parse(body("channel_unarchived", actor: jt, target: nil)) == .channelUnarchived(actor: jt)
        )
    }

    @Test("a change that clears the value has no sentence, so it is absent rather than empty")
    func clearedValueIsNil() {
        #expect(SystemNotice.parse(body("topic_changed", actor: jt, target: nil, extra: "\"topic\":\"\"")) == nil)
        #expect(SystemNotice.parse(body("topic_changed", actor: jt, target: nil)) == nil)
        #expect(SystemNotice.parse(body("purpose_changed", actor: jt, target: nil, extra: "\"purpose\":\"\"")) == nil)
    }

    @Test("a type this build does not know decodes to nothing rather than to a blank row")
    func unknownTypeIsNil() {
        // Two the relay really emits and neither reference client renders, plus the
        // moderation tombstone, which is a separate decision: a deleted message already
        // leaves the timeline here, so whether it should also leave a mark is its own
        // question.
        #expect(SystemNotice.parse(body("ttl_changed", actor: jt, target: nil)) == nil)
        #expect(SystemNotice.parse(body("visibility_changed", actor: jt, target: nil)) == nil)
        #expect(SystemNotice.parse(body("message_deleted", actor: jt, target: nil)) == nil)
    }

    @Test("the subject is who the row is about: the arrival, or otherwise the actor")
    func subject() {
        // The asymmetry the reference clients have, pinned: an add is a row about the
        // person added, an eviction a row about the person who did it.
        #expect(SystemNotice.memberJoined(actor: jt, target: sentry).subject == sentry)
        #expect(SystemNotice.memberJoined(actor: sentry, target: sentry).subject == sentry)
        #expect(SystemNotice.memberRemoved(actor: jt, target: sentry).subject == jt)
        #expect(SystemNotice.memberLeft(actor: sentry).subject == sentry)
        #expect(SystemNotice.topicChanged(actor: jt, topic: "x").subject == jt)
        #expect(SystemNotice.channelCreated(actor: jt).subject == jt)
    }

    @Test("a notice that cannot name who it is about is absent, not blank")
    func missingParticipantIsNil() {
        #expect(SystemNotice.parse(body("member_joined", actor: jt, target: nil)) == nil)
        #expect(SystemNotice.parse(body("member_removed", actor: nil, target: sentry)) == nil)
        #expect(SystemNotice.parse(body("member_left", actor: nil, target: nil)) == nil)
    }

    @Test("a body that is not a notice at all decodes to nothing")
    func malformedIsNil() {
        #expect(SystemNotice.parse("") == nil)
        #expect(SystemNotice.parse("not json") == nil)
        #expect(SystemNotice.parse("{\"actor\":\"\(jt)\"}") == nil)
    }

    @Test("a participant that is not a pubkey is rejected, so nothing renders a fragment of it")
    func rejectsNonPubkeyParticipants() {
        #expect(SystemNotice.parse(body("member_left", actor: "sentry", target: nil)) == nil)
        #expect(SystemNotice.parse(body("member_left", actor: String(repeating: "a", count: 63), target: nil)) == nil)
        #expect(SystemNotice.parse(body("member_left", actor: String(repeating: "z", count: 64), target: nil)) == nil)
    }

    @Test("uppercase hex normalizes, so it resolves against the same profile row")
    func normalizesCase() {
        let shouty = String(repeating: "A", count: 64)
        #expect(SystemNotice.parse(body("member_left", actor: shouty, target: nil)) == .memberLeft(actor: jt))
    }

    @Test("participants lists everyone the sentence will name")
    func participants() {
        #expect(SystemNotice.memberLeft(actor: sentry).participants == [sentry])
        #expect(SystemNotice.memberRemoved(actor: jt, target: sentry).participants == [jt, sentry])
    }
}

/// The words each notice reads as, and what changes when one of the people is the
/// reader.
@Suite("System notice sentences", .timeLimit(.minutes(1)))
struct SystemNoticeSentenceTests {
    private let jt = String(repeating: "a", count: 64)
    private let sentry = String(repeating: "b", count: 64)

    /// Resolves the two test keys and nothing else — a name this cannot resolve should
    /// never reach it, and returning something obviously wrong makes that visible.
    private func name(_ pubkey: String) -> String {
        switch pubkey {
        case jt: "JT"
        case sentry: "Sentry"
        default: "UNRESOLVED"
        }
    }

    private func sentence(_ notice: SystemNotice, reader: String? = nil) -> String {
        SystemNoticeSentence(notice, name: name, selfPubkey: reader).plain
    }

    @Test("third person, when the reader is nobody in the sentence")
    func thirdPerson() {
        #expect(sentence(.memberJoined(actor: sentry, target: sentry)) == "Sentry joined the channel")
        #expect(sentence(.memberJoined(actor: jt, target: sentry)) == "Sentry was added by JT")
        #expect(sentence(.memberLeft(actor: sentry)) == "Sentry left the channel")
        #expect(sentence(.memberRemoved(actor: jt, target: sentry)) == "JT removed Sentry from the channel")
    }

    @Test("the reader in subject position takes You, and the verb agrees with it")
    func readerAsSubject() {
        // The conjugation is the point: Desktop substitutes the literal "You" and
        // produces "You was added by JT".
        #expect(sentence(.memberJoined(actor: jt, target: sentry), reader: sentry) == "You were added by JT")
        #expect(sentence(.memberJoined(actor: sentry, target: sentry), reader: sentry) == "You joined the channel")
        #expect(sentence(.memberLeft(actor: sentry), reader: sentry) == "You left the channel")
        #expect(
            sentence(.memberRemoved(actor: jt, target: sentry), reader: jt) == "You removed Sentry from the channel"
        )
    }

    @Test("the reader in object position takes the object form")
    func readerAsObject() {
        #expect(sentence(.memberJoined(actor: jt, target: sentry), reader: jt) == "Sentry was added by you")
        #expect(
            sentence(.memberRemoved(actor: jt, target: sentry), reader: sentry) == "JT removed you from the channel"
        )
    }

    @Test("a keyless session reads every notice in the third person, which is true for it")
    func keylessSession() {
        #expect(sentence(.memberJoined(actor: jt, target: sentry), reader: nil) == "Sentry was added by JT")
    }

    @Test("the names are marked so the view can weight them, and nothing else is")
    func namesAreMarked() {
        let action = SystemNoticeSentence(
            .memberRemoved(actor: jt, target: sentry),
            name: name,
            selfPubkey: nil
        ).action
        #expect(action.filter(\.isName).map(\.text) == ["Sentry"])
        #expect(action.filter { !$0.isName }.map(\.text) == ["removed ", " from the channel"])
    }

    @Test("the subject goes in the header and the predicate never repeats it")
    func titleAndActionAreSeparate() {
        // The row draws the title beside a face and the action under it, so an action
        // that still carried the name would print it twice.
        let added = SystemNoticeSentence(.memberJoined(actor: jt, target: sentry), name: name, selfPubkey: nil)
        #expect(added.title == "Sentry")
        #expect(added.action.map(\.text).joined() == "was added by JT")
        #expect(added.plain == "Sentry was added by JT")

        // And on the case whose subject is the actor rather than the target.
        let removed = SystemNoticeSentence(.memberRemoved(actor: jt, target: sentry), name: name, selfPubkey: nil)
        #expect(removed.title == "JT")
        #expect(removed.action.map(\.text).joined() == "removed Sentry from the channel")
    }

    @Test("the reader's own name reaches the header too, so a row about them says so")
    func titleTakesTheSecondPerson() {
        let sentence = SystemNoticeSentence(
            .memberJoined(actor: jt, target: sentry),
            name: name,
            selfPubkey: sentry
        )
        #expect(sentence.title == "You")
    }

    @Test("what happened to the channel itself reads as a sentence about who did it")
    func channelSentences() {
        let quoted = "JT changed the topic to \u{201C}Ship it\u{201D}"
        #expect(sentence(.topicChanged(actor: jt, topic: "Ship it")) == quoted)
        #expect(
            sentence(.purposeChanged(actor: jt, purpose: "Releases"))
                == "JT changed the purpose to \u{201C}Releases\u{201D}"
        )
        #expect(sentence(.channelCreated(actor: jt)) == "JT created this channel")
        #expect(sentence(.channelArchived(actor: jt)) == "JT archived this channel")
        #expect(sentence(.channelUnarchived(actor: jt)) == "JT unarchived this channel")
        #expect(sentence(.channelCreated(actor: jt), reader: jt) == "You created this channel")
    }

    @Test("a topic is quoted, not weighted: it is the thing said, not somebody who said it")
    func topicIsNotAName() {
        let changed = SystemNoticeSentence(.topicChanged(actor: jt, topic: "Ship it"), name: name, selfPubkey: nil)
        #expect(changed.action.contains(where: \.isName) == false)
    }
}

/// Where a notice lands in a rendered conversation.
@Suite("System notices in a conversation", .timeLimit(.minutes(1)))
struct SystemNoticeGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let sentry = String(repeating: "b", count: 64)

    private func joinBody() -> String {
        "{\"type\":\"member_joined\",\"actor\":\"\(sentry)\",\"target\":\"\(sentry)\"}"
    }

    @Test("a notice becomes its own item, interleaved by time")
    func noticeIsItsOwnItem() {
        let items = ConversationGrouping.items(
            for: [
                makeRow(id: "1", at: 1_000, content: "before"),
                makeNoticeRow(
                    id: "n", at: 1_100, body: joinBody(),
                    notice: .memberJoined(actor: sentry, target: sentry)
                ),
                makeRow(id: "2", at: 1_200, content: "after"),
            ],
            calendar: calendar
        )
        #expect(shape(items) == ["day", "before", "notice", "after"])
        // The raw JSON body must not be reachable as a message.
        #expect(items.compactMap(\.message).map(\.content) == ["before", "after"])
    }

    @Test("a notice this build cannot read is dropped, and does not leave an empty day behind")
    func undecodableNoticeIsDropped() {
        // A whole day whose only event is a notice from a future relay: the day
        // separator must go with it, or the conversation grows a date heading with
        // nothing under it.
        let items = ConversationGrouping.items(
            for: [
                makeRow(id: "1", at: 1_000, content: "monday"),
                makeNoticeRow(id: "n", at: 200_000, body: "{\"type\":\"ttl_changed\"}", notice: nil),
            ],
            calendar: calendar
        )
        #expect(shape(items) == ["day", "monday"])
    }

    @Test("a conversation whose newest event is a notice lands on the notice")
    func newestItemCanBeANotice() {
        let items = ConversationGrouping.items(
            for: [
                makeRow(id: "1", at: 1_000, content: "before"),
                makeNoticeRow(
                    id: "n", at: 1_100, body: joinBody(),
                    notice: .memberJoined(actor: sentry, target: sentry)
                ),
            ],
            calendar: calendar
        )
        // Landing on "1" would leave the newest thing in the conversation below the fold.
        #expect(items.newestMessageID == "n")
    }

    @Test("a dropped notice never becomes the thing a conversation scrolls to")
    func droppedNoticeIsNotTheTail() {
        let items = ConversationGrouping.items(
            for: [
                makeRow(id: "1", at: 1_000, content: "before"),
                makeNoticeRow(id: "n", at: 1_100, body: "{}", notice: nil),
            ],
            calendar: calendar
        )
        #expect(items.newestMessageID == "1")
    }
}
