@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

// A group direct message in the seconds before its roster exists.
//
// The relay commits the channel and publishes its membership *afterwards*, so the picker
// hands back a channel id that nothing can yet answer "who is in this?" for. The people
// that were picked travel with the push and stand in until the projection catches up —
// the same gap the one-to-one hint fills (``EntityNamesTests``), for a group.
//
// An extension of ``GroupDirectMessageTests`` rather than its own suite, because these are
// the same rule about the same conversation and share its resolvers.
extension GroupDirectMessageTests {
    /// The row the sidebar fabricates for a conversation the relay has only just answered
    /// with: no name, and — the part that matters here — no `t=dm` either, because the
    /// channel is not in the projected list yet. So the roster rule cannot fire for it, and
    /// a group opened seconds ago has nothing at all to be named by.
    private func unprojectedRow(_ id: String = "gdm") -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: nil,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }

    @Test("a group opened seconds ago is titled by the people who were picked")
    func hintedGroupIsNamedBeforeItsRoster() {
        let hinted = names(rosters: [:], channels: [])
            .conversation(for: unprojectedRow(), knownPeers: [cy, ada, bo])

        #expect(hinted.kind == .group)
        #expect(hinted.title == "Ada, Bo, Cy")
        // No peer, for the same reason a projected group has none: nobody in particular is
        // on the other end of it.
        #expect(hinted.peer == nil)
        // The people picked, plus you — the number the roster lands with, so the mark does
        // not tick up under a reader already looking at it.
        #expect(hinted.memberCount == 4)
    }

    /// Why the hint and the roster share one join: two spellings of "how a group is named"
    /// would make the arrival of the membership a visible flash, which is the whole thing
    /// the hint exists to prevent.
    @Test("the title the hint draws is the one the roster produces, character for character")
    func hintedTitleMatchesTheProjectedOne() {
        let hinted = names(rosters: [:], channels: [])
            .conversation(for: unprojectedRow(), knownPeers: [cy, ada, bo])
        let projected = names(rosters: ["gdm": [me, ada, bo, cy]], channels: [groupRow()])
            .conversation(for: "gdm")

        #expect(hinted.title == projected.title)
        #expect(hinted.kind == projected.kind)
        #expect(hinted.memberCount == projected.memberCount)
    }

    @Test("the roster wins the moment it lands, whoever the tap named")
    func rosterOutranksTheHint() {
        let resolver = names(rosters: ["gdm": [me, ada, bo]], channels: [groupRow()])
        // Naming somebody who is not in the room changes nothing: a hint stands in before
        // the rule has anything to apply, it does not argue with the rule's answer.
        #expect(resolver.conversation(for: groupRow(), knownPeers: [ada, bo, cy]).title == "Ada, Bo")
    }

    @Test("you are never one of the people a hinted group is named by, however it was spelled")
    func hintDropsSelfAndDuplicates() {
        let hinted = names(rosters: [:], channels: []).conversation(
            for: unprojectedRow(),
            knownPeers: [ada, me, bo.uppercased(), bo]
        )

        #expect(hinted.title == "Ada, Bo")
        #expect(hinted.memberCount == 3)
    }

    @Test("one person picked is a one-to-one, not a group of one")
    func oneHintedPersonIsNotAGroup() {
        let hinted = names(rosters: [:], channels: [])
            .conversation(for: unprojectedRow("dm"), knownPeers: [ada])

        #expect(hinted.kind == .direct)
        #expect(hinted.isOneToOne)
        #expect(hinted.title == "Ada")
    }
}
