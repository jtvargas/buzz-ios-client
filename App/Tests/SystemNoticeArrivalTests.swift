@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// Keys `01…`, `02…` resolving to "P1", "P2" — distinct in their first byte so an
/// assertion that reordered them would read differently, and any number can be asked
/// for, which the overflow cases need.
private func person(_ index: Int) -> String {
    String(format: "%02d", index) + String(repeating: "0", count: 62)
}

/// The one doing the adding, and nobody who ever arrives.
private let adder = String(repeating: "a", count: 64)

/// Resolves the keys above and nothing else — a name this cannot resolve should never
/// reach it, and returning something obviously wrong makes that visible.
private func personName(_ pubkey: String) -> String {
    if pubkey == adder { return "JT" }
    guard let index = Int(pubkey.prefix(2)) else { return "UNRESOLVED" }
    return "P\(index)"
}

/// The sentence a collapsed run of arrivals reads as.
///
/// List grammar is the part that is easy to get subtly wrong — a stray comma before
/// "and", a plural on one person, a count that gets weighted as if it were somebody's
/// name.
@Suite("Collapsed arrival sentences", .timeLimit(.minutes(1)))
struct CollapsedArrivalSentenceTests {
    private func added(_ count: Int, reader: String? = nil) -> String {
        let targets = (1...count).map(person)
        return SystemNoticeSentence(
            .memberJoined(actor: adder, target: targets[0]),
            alsoJoined: Array(targets.dropFirst()),
            name: personName,
            selfPubkey: reader
        ).plain
    }

    @Test("two, three and four people read as a list; past that the rest become a count")
    func listGrammar() {
        #expect(added(1) == "P1 was added by JT")
        #expect(added(2) == "P1 was added by JT, along with P2")
        #expect(added(3) == "P1 was added by JT, along with P2 and P3")
        #expect(added(4) == "P1 was added by JT, along with P2, P3, and P4")
        #expect(added(5) == "P1 was added by JT, along with P2, P3, P4, and 1 other")
        #expect(added(7) == "P1 was added by JT, along with P2, P3, P4, and 3 others")
    }

    @Test("a shared self-join says who joined with whom, and names no adder")
    func selfJoinRun() {
        let sentence = SystemNoticeSentence(
            .memberJoined(actor: person(1), target: person(1)),
            alsoJoined: [person(2), person(3)],
            name: personName,
            selfPubkey: nil
        )
        #expect(sentence.plain == "P1 joined the channel along with P2 and P3")
    }

    @Test("the reader among the others takes the object form, like any other object")
    func readerAmongTheOthers() {
        #expect(added(2, reader: person(2)) == "P1 was added by JT, along with you")
    }

    @Test("the count is a count, not a name — only people are weighted")
    func countIsNotAName() {
        let sentence = SystemNoticeSentence(
            .memberJoined(actor: adder, target: person(1)),
            alsoJoined: (2...6).map(person),
            name: personName,
            selfPubkey: nil
        )
        #expect(sentence.action.filter(\.isName).map(\.text) == ["JT", "P2", "P3", "P4"])
        #expect(sentence.action.contains { $0.isName && $0.text.contains("other") } == false)
    }
}

/// Which arrivals are allowed to share a row.
///
/// Adding four people emits four notices, and both reference clients fold them into one
/// line rather than stacking four identical rows
/// (`SystemMessageRow.tsx`'s `buildGroupedMembershipPayload`, `system_rows.dart`'s
/// `_membershipDisplayEvent`). The rules are theirs; these pin them, and pin the one
/// consequence that reaches the scroll engine.
@Suite("Collapsed arrivals in a conversation", .timeLimit(.minutes(1)))
struct CollapsedArrivalGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func arrival(_ id: String, at createdAt: Int64, actor: String, target: String) -> TimelineRow {
        makeNoticeRow(
            id: id,
            at: createdAt,
            body: "{\"type\":\"member_joined\",\"actor\":\"\(actor)\",\"target\":\"\(target)\"}",
            notice: .memberJoined(actor: actor, target: target)
        )
    }

    /// Every arrival added by `adder`, one second apart, in one conversation.
    private func addedInARow(_ count: Int) -> [ConversationItem] {
        ConversationGrouping.items(
            for: (1...count).map { arrival("n\($0)", at: 1_000 + Int64($0), actor: adder, target: person($0)) },
            calendar: calendar
        )
    }

    private func firstNotice(_ items: [ConversationItem]) -> NoticeMarker? {
        items.compactMap { if case let .notice(marker) = $0 { marker } else { nil } }.first
    }

    @Test("adding three people is one row naming all three, not three rows")
    func addsCollapse() {
        let items = addedInARow(3)
        #expect(items.filter(\.isContent).count == 1)
        let marker = firstNotice(items)
        // The head's own target is named by the notice; the rest ride alongside it.
        #expect(marker?.notice == .memberJoined(actor: adder, target: person(1)))
        #expect(marker?.alsoJoined == [person(2), person(3)])
    }

    @Test("the collapsed row keeps the first arrival's id, so a later one is not content moving above the reader")
    func collapsedRowKeepsTheHeadID() {
        let two = addedInARow(2)
        #expect(two.newestMessageID == "n1")
        // The whole point: a third person joining a group already on screen changes the
        // row's *contents*, not the list of ids — so the scaffold treats it as a row
        // growing where it stands rather than as content arriving above the reader.
        #expect(two.isStructuralChange(to: addedInARow(3)) == false)
    }

    @Test("two people adding one person each stay two rows: 'was added by' has one slot")
    func differentActorsDoNotCollapse() {
        let items = ConversationGrouping.items(
            for: [
                arrival("n1", at: 1_001, actor: adder, target: person(1)),
                arrival("n2", at: 1_002, actor: person(9), target: person(2)),
            ],
            calendar: calendar
        )
        #expect(items.filter(\.isContent).count == 2)
    }

    @Test("a run of self-joins collapses on nobody, because each person is their own actor")
    func selfJoinsCollapse() {
        let items = ConversationGrouping.items(
            for: (1...2).map { arrival("n\($0)", at: 1_000 + Int64($0), actor: person($0), target: person($0)) },
            calendar: calendar
        )
        #expect(items.filter(\.isContent).count == 1)
        #expect(firstNotice(items)?.alsoJoined == [person(2)])
    }

    @Test("a self-join and an add are different sentences and never share a row")
    func selfJoinDoesNotMixWithAnAdd() {
        let items = ConversationGrouping.items(
            for: [
                arrival("n1", at: 1_001, actor: person(1), target: person(1)),
                arrival("n2", at: 1_002, actor: adder, target: person(2)),
            ],
            calendar: calendar
        )
        #expect(items.filter(\.isContent).count == 2)
    }

    @Test("a group spans five minutes at most, measured from its head, so arrivals cannot chain all afternoon")
    func groupIsBoundedByTime() {
        let window = Int64(ConversationGrouping.groupWindow)
        // Each gap is inside the window and the span is not: 0, +4min, +8min. A
        // neighbour-to-neighbour rule would fold all three into one row dated at the
        // first, eight minutes before the last thing it claims to describe.
        let items = ConversationGrouping.items(
            for: [
                arrival("n1", at: 1_000, actor: adder, target: person(1)),
                arrival("n2", at: 1_000 + window - 60, actor: adder, target: person(2)),
                arrival("n3", at: 1_000 + 2 * (window - 60), actor: adder, target: person(3)),
            ],
            calendar: calendar
        )
        #expect(items.filter(\.isContent).count == 2)
        #expect(firstNotice(items)?.alsoJoined == [person(2)])
    }

    @Test("an arrival that appears to precede the row it would join is left alone")
    func backwardsClockDoesNotGroup() {
        let items = ConversationGrouping.items(
            for: [
                arrival("n1", at: 2_000, actor: adder, target: person(1)),
                arrival("n2", at: 1_000, actor: adder, target: person(2)),
            ],
            calendar: calendar
        )
        #expect(items.filter(\.isContent).count == 2)
    }

    @Test("a message between two adds breaks the run, and so does a new day")
    func adjacencyIsRequired() {
        let interrupted = ConversationGrouping.items(
            for: [
                arrival("n1", at: 1_001, actor: adder, target: person(1)),
                makeRow(id: "m", at: 1_002, content: "hello"),
                arrival("n2", at: 1_003, actor: adder, target: person(2)),
            ],
            calendar: calendar
        )
        #expect(shape(interrupted) == ["day", "notice", "hello", "notice"])

        // 200_000s apart is a different UTC day, so a separator lands between them.
        let acrossMidnight = ConversationGrouping.items(
            for: [
                arrival("n1", at: 1_001, actor: adder, target: person(1)),
                arrival("n2", at: 200_000, actor: adder, target: person(2)),
            ],
            calendar: calendar
        )
        #expect(shape(acrossMidnight) == ["day", "notice", "day", "notice"])
    }

    @Test("an undecodable notice between two adds does not separate them, having been dropped before this")
    func droppedNoticeDoesNotBreakARun() {
        let items = ConversationGrouping.items(
            for: [
                arrival("n1", at: 1_001, actor: adder, target: person(1)),
                makeNoticeRow(id: "x", at: 1_002, body: "{\"type\":\"ttl_changed\"}", notice: nil),
                arrival("n2", at: 1_003, actor: adder, target: person(2)),
            ],
            calendar: calendar
        )
        // The dropped row was never an item, so the two arrivals are adjacent and merge.
        #expect(items.filter(\.isContent).count == 1)
        #expect(firstNotice(items)?.alsoJoined == [person(2)])
    }
}
