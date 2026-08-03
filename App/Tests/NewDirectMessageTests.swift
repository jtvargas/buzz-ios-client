@testable import Hive
import Foundation
import Testing

/// The rules the new-direct-message picker applies, tested against the rules rather than
/// through a layout.
///
/// That separation is the point of ``DirectMessagePicker`` being a value with no view in
/// it: who is offered, in what order, what a typed query does to that order, and what the
/// cap refuses are all answerable here, with no relay, no store, and no simulator.
@Suite("New direct message picker", .timeLimit(.minutes(1)))
struct NewDirectMessageTests {
    private static func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private static func person(
        _ byte: UInt8,
        _ name: String,
        secondary: String? = nil,
        isAgent: Bool = false,
        isNamed: Bool = true
    ) -> DirectMessagePerson {
        DirectMessagePerson(
            pubkey: key(byte),
            name: name,
            secondary: secondary,
            isAgent: isAgent,
            isNamed: isNamed
        )
    }

    private static func makePicker(
        _ people: [DirectMessagePerson],
        cap: Int = 8
    ) -> DirectMessagePicker {
        DirectMessagePicker(people: people, maxSelection: cap)
    }

    private let ada = Self.person(0x11, "Ada Lovelace", secondary: "ada@buzz.dev")
    private let bo = Self.person(0x22, "Bo Jordan")
    private let cy = Self.person(0x33, "Cy")
    private let jarvis = Self.person(0x44, "Jarvis", secondary: "Agent", isAgent: true)
    private let nameless = Self.person(0x55, "npub1qqqqqq…qqqq", isNamed: false)

    // MARK: - Resting order

    @Test("An empty query offers everyone, people before agents and named before not")
    func restingOrder() {
        let picker = Self.makePicker([jarvis, nameless, cy, ada, bo])
        #expect(picker.results.map(\.name) == [
            "Ada Lovelace",
            "Bo Jordan",
            "Cy",
            "npub1qqqqqq…qqqq",
            "Jarvis",
        ])
    }

    @Test("Whitespace alone is still an empty query, not a search for a space")
    func blankQueryIsEmpty() {
        var picker = Self.makePicker([ada, bo])
        picker.query = "   "
        #expect(picker.results.count == 2)
    }

    @Test("Two identical names are still ordered, by key")
    func identicalNamesTieOnKey() {
        let first = Self.person(0x11, "Ada")
        let second = Self.person(0x99, "Ada")
        let picker = Self.makePicker([second, first])
        #expect(picker.results.map(\.pubkey) == [first.pubkey, second.pubkey])
    }

    // MARK: - Ranking

    @Test("Exact, then prefix, then interior word, then its prefix, then anywhere at all")
    func rankingTiers() {
        var picker = Self.makePicker([
            Self.person(0x11, "Ada Lovelace"), // the name starts with it
            Self.person(0x22, "Ad"), // no match at all
            Self.person(0x33, "Bo Ada"), // a whole word inside the name
            Self.person(0x44, "Cy Adamson"), // a word inside the name starts with it
            Self.person(0x55, "Jadan"), // only somewhere inside a word
            Self.person(0x66, "Ada"), // exact — the whole name is the query
        ])
        picker.query = "ada"
        #expect(picker.results.map(\.name) == [
            "Ada",
            "Ada Lovelace",
            "Bo Ada",
            "Cy Adamson",
            "Jadan",
        ])
    }

    @Test("A superset of a name matches, and never outranks a real word match")
    func substringTierRanksLast() {
        var picker = Self.makePicker([bo, Self.person(0x66, "Dan Reed")])
        picker.query = "dan"
        // `Bo Jordan` contains it; `Dan Reed` starts with it. The picker offers both, in
        // that order.
        #expect(picker.results.map(\.name) == ["Dan Reed", "Bo Jordan"])
        // And the composer, which does not ask for the substring tier, offers only one —
        // the guarantee that lifting the scorer changed nothing on that surface.
        #expect(NameMatch(name: "Bo Jordan").score(for: "dan") == nil)
        #expect(NameMatch(name: "Bo Jordan").score(for: "dan", allowingSubstring: true) != nil)
    }

    @Test("A NIP-05 matches at name priority, and case and accents are folded away")
    func secondaryAndFolding() {
        var picker = Self.makePicker([ada, Self.person(0x66, "José")])
        picker.query = "ADA@BUZZ"
        #expect(picker.results.map(\.name) == ["Ada Lovelace"])
        picker.query = "jose"
        #expect(picker.results.map(\.name) == ["José"])
    }

    @Test("A pasted key finds its person")
    func identifierPrefix() {
        var picker = Self.makePicker([ada, bo])
        picker.query = String(bo.pubkey.prefix(12))
        #expect(picker.results.map(\.name) == ["Bo Jordan"])
    }

    @Test("Nothing matching is an empty list, not the whole roster")
    func noMatches() {
        var picker = Self.makePicker([ada, bo])
        picker.query = "zzz"
        #expect(picker.results.isEmpty)
    }

    @Test("Agents are offered, below a person who matches as well")
    func agentsRankBelowPeople() {
        var picker = Self.makePicker([jarvis, Self.person(0x66, "Jar Jar")])
        picker.query = "jar"
        #expect(picker.results.map(\.name) == ["Jar Jar", "Jarvis"])
    }

    // MARK: - Selection

    @Test("Chips read in the order they were picked, not the list's order")
    func chipsFollowPickOrder() {
        var picker = Self.makePicker([ada, bo, cy])
        picker.toggle(cy.pubkey)
        picker.toggle(ada.pubkey)
        #expect(picker.chips.map(\.name) == ["Cy", "Ada Lovelace"])
        #expect(picker.canStart)
    }

    @Test("A selection survives a query that hides it — which is what the chips are for")
    func selectionSurvivesFiltering() {
        var picker = Self.makePicker([ada, bo])
        picker.toggle(ada.pubkey)
        picker.query = "bo"
        #expect(picker.results.map(\.name) == ["Bo Jordan"])
        #expect(picker.chips.map(\.name) == ["Ada Lovelace"])
    }

    @Test("Picking twice unpicks")
    func toggleIsIdempotentInPairs() {
        var picker = Self.makePicker([ada])
        picker.toggle(ada.pubkey)
        picker.toggle(ada.pubkey)
        #expect(picker.selection.isEmpty)
        #expect(!picker.canStart)
    }

    @Test("Nobody picked means nothing to start")
    func emptySelectionCannotStart() {
        #expect(!Self.makePicker([ada, bo]).canStart)
    }

    // MARK: - The cap

    @Test("The cap refuses the ninth person, and unpicking is still the way back")
    func capRefusesOverflow() {
        let roster = (1 ... 9).map { Self.person(UInt8($0), "Person \($0)") }
        var picker = Self.makePicker(roster)
        for person in roster { picker.toggle(person.pubkey) }
        #expect(picker.selection.count == 8)
        #expect(picker.isFull)
        // The one that did not fit is drawn disabled; the eight that did are still live,
        // because unpicking one is the only way back from a full sheet.
        #expect(!picker.canSelect(roster[8].pubkey))
        #expect(picker.canSelect(roster[0].pubkey))
        picker.toggle(roster[0].pubkey)
        #expect(picker.selection.count == 7)
        #expect(picker.canSelect(roster[8].pubkey))
    }

    @Test("The cap is the caller's number, not the picker's")
    func capIsInjected() {
        var picker = Self.makePicker([ada, bo, cy], cap: 2)
        for person in [ada, bo, cy] { picker.toggle(person.pubkey) }
        #expect(picker.selection == [ada.pubkey, bo.pubkey])
    }

    @Test("A chip removed by tapping it leaves the rest alone")
    func deselectOne() {
        var picker = Self.makePicker([ada, bo, cy])
        for person in [ada, bo, cy] { picker.toggle(person.pubkey) }
        picker.deselect(bo.pubkey)
        #expect(picker.chips.map(\.name) == ["Ada Lovelace", "Cy"])
    }

    @Test("A key is one key however it was spelled")
    func selectionIsCaseInsensitive() {
        var picker = Self.makePicker([ada])
        picker.toggle(ada.pubkey.uppercased())
        #expect(picker.isSelected(ada.pubkey))
        #expect(picker.selection == [ada.pubkey])
    }
}
