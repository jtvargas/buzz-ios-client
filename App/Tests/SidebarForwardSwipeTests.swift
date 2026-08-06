import BuzzKit
@testable import Hive
import Foundation
import SwiftUI
import Testing
import UIKit

/// The leftward drag on the sidebar that reopens the conversation just left: what it
/// remembers, and what a hand's travel means.
///
/// The transition itself is not here and cannot be — it is a UIKit snapshot, a window and
/// two transforms, and what it does is only true on a display. What *is* here is everything
/// that decides: the slot, and the arithmetic between a finger and a decision. Both were the
/// parts that could be wrong without anyone noticing on the device.
@Suite("Sidebar forward swipe", .timeLimit(.minutes(1)))
struct SidebarForwardSwipeTests {
    // MARK: - What is remembered

    @Test("leaving a conversation for the sidebar is what fills the slot")
    func leavingFillsTheSlot() {
        var resume = ConversationResume()
        #expect(resume.conversation == nil)

        // Opening one records nothing: where you are going is on screen.
        resume.observe(path: [Self.route("general")], previously: [])
        #expect(resume.conversation == nil)

        // Backing out of it does.
        resume.observe(path: [], previously: [Self.route("general")])
        #expect(resume.conversation?.channel.id == "general")
    }

    @Test("popping to a conversation underneath leaves the slot alone")
    func poppingOntoAnotherConversationChangesNothing() {
        // Reachable without doing anything strange: a `#channel` reference inside a message,
        // or a profile sheet's Message action, pushes a second conversation onto the first.
        // Backing out of that one leaves the reader *in* a conversation, which is on screen —
        // so there is nothing to remember, and remembering it would mark a row for a
        // conversation the reader can already see they are in.
        var resume = ConversationResume()
        resume.observe(path: [], previously: [Self.route("general")])
        resume.observe(
            path: [Self.route("general")],
            previously: [Self.route("general"), Self.route("design")]
        )
        #expect(resume.conversation?.channel.id == "general")
    }

    @Test("the slot is the last conversation left, not the first")
    func theSlotIsOverwritten() {
        var resume = ConversationResume()
        resume.observe(path: [], previously: [Self.route("general")])
        resume.observe(path: [], previously: [Self.route("design")])
        #expect(resume.conversation?.channel.id == "design")
    }

    @Test("an empty path that was already empty says nothing")
    func anEmptyChangeSaysNothing() {
        // The state a launch starts in, and one an unrelated body pass can re-deliver.
        var resume = ConversationResume()
        resume.observe(path: [], previously: [])
        #expect(resume.conversation == nil)
    }

    // MARK: - Whether the slot still points at anything

    @Test("a conversation the sidebar no longer lists is not offered")
    func aConversationThatLeftTheSidebarIsDropped() {
        // Hiding a direct message takes it off this sidebar (kind 41012) while it is in the
        // slot — so does being removed from a channel. Reopening one would put the reader
        // somewhere the sidebar says they cannot go, with a highlight on a row that is not
        // there to explain it.
        var resume = ConversationResume()
        resume.observe(path: [], previously: [Self.route("general")])

        #expect(resume.resolved(among: [Self.row("general"), Self.row("design")])?.channel.id == "general")
        #expect(resume.resolved(among: [Self.row("design")]) == nil)
        // The state every launch begins in, and every reconnect passes through.
        #expect(resume.resolved(among: []) == nil)
    }

    @Test("nothing is offered before anything has been left")
    func anEmptySlotOffersNothing() {
        #expect(ConversationResume().resolved(among: [Self.row("general")]) == nil)
    }

    // MARK: - What a hand's travel means

    @Test("progress is the share of the screen crossed, leftward only")
    func progressIsTheShareOfTheScreenCrossed() {
        let width: CGFloat = 400
        #expect(ForwardSwipeGeometry.progress(translation: 0, width: width) == 0)
        // Leftward is negative in UIKit; this is the sign flip that makes it a fraction.
        #expect(ForwardSwipeGeometry.progress(translation: -100, width: width) == 0.25)
        #expect(ForwardSwipeGeometry.progress(translation: -200, width: width) == 0.5)
        #expect(ForwardSwipeGeometry.progress(translation: -400, width: width) == 1)
        // Both ends clamp. Dragging back past where the finger started does not push the
        // sidebar off the other edge, and there is nothing past the conversation to reveal.
        #expect(ForwardSwipeGeometry.progress(translation: 120, width: width) == 0)
        #expect(ForwardSwipeGeometry.progress(translation: -900, width: width) == 1)
        // A width of zero is the frame before a view has been laid out, not a real screen.
        #expect(ForwardSwipeGeometry.progress(translation: -100, width: 0) == 0)
    }

    @Test("a release opens the conversation on distance or on speed")
    func aReleaseCommitsOnDistanceOrSpeed() {
        let slow: CGFloat = 0
        // Distance alone, either side of the threshold.
        #expect(ForwardSwipeGeometry.commits(progress: 0.4, velocity: slow))
        #expect(!ForwardSwipeGeometry.commits(progress: 0.2, velocity: slow))
        // Speed alone: a flick that has covered almost nothing still means it.
        #expect(ForwardSwipeGeometry.commits(progress: 0.05, velocity: -1200))
        // And the same rule mirrored, which is how someone changes their mind: thrown back
        // to the right from four fifths of the way over, this closes.
        #expect(!ForwardSwipeGeometry.commits(progress: 0.8, velocity: 1200))
    }

    @Test("the release takes longer the further it has to go, within bounds")
    func theReleaseIsProportionalWithinBounds() {
        let width: CGFloat = 400
        let short = ForwardSwipeGeometry.settleDuration(from: 0.9, to: 1, width: width, velocity: 0)
        let long = ForwardSwipeGeometry.settleDuration(from: 0.1, to: 1, width: width, velocity: 0)
        #expect(short < long)
        // Bounded at both ends: a near-finished release is not an instant jump, and a slow
        // one does not outstay the hand that let go of it.
        for (from, to, velocity) in [(0.999, 1.0, 0.0), (0.0, 1.0, 0.0), (0.5, 1.0, 4000.0)] {
            let duration = ForwardSwipeGeometry.settleDuration(
                from: CGFloat(from),
                to: CGFloat(to),
                width: width,
                velocity: CGFloat(velocity)
            )
            #expect(duration >= ForwardSwipeGeometry.minimumSettle)
            #expect(duration <= ForwardSwipeGeometry.maximumSettle)
        }
    }

    @Test("the arriving conversation is held off by the same share the system's push moves by")
    func theParallaxMatchesTheSystemPush() {
        // Pinned because it is the number that makes this read as the back swipe mirrored
        // rather than as a drawer: 30% is what UIKit moves the outgoing screen by, and this
        // is that applied to the one arriving.
        #expect(ForwardSwipeGeometry.parallax == 0.3)
        // A shade that reached 1 would black the conversation out rather than sit it behind
        // the sidebar, and one at 0 would lose the depth the gesture reads by.
        #expect(ForwardSwipeGeometry.shade > 0 && ForwardSwipeGeometry.shade < 0.3)
    }

    // MARK: - What a drag will share a touch with

    @MainActor
    @Test("a drag shares a touch with a scroll and with nothing else")
    func aDragSharesOnlyWithScrolling() {
        let sidebar = SidebarForwardSwipeView()
        let drag = LeftwardPanGestureRecognizer()

        // The list's own vertical scrolling, which has to keep running: this recogniser
        // cannot know the hand's direction until 10pt in, and a scroll made to wait for that
        // would begin late every time.
        #expect(sidebar.gestureRecognizer(drag, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))

        // Everything else. A row is a `Button`, and sharing the touch with its press is what
        // let a drag beginning on row C navigate to C on release — on top of the conversation
        // the drag had just reopened.
        #expect(!sidebar.gestureRecognizer(drag, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
        #expect(!sidebar.gestureRecognizer(drag, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()))
    }

    // MARK: - Fixtures

    private static func route(_ id: String) -> ConversationRoute {
        ConversationRoute(channel: row(id))
    }

    private static func row(_ id: String) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: id,
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }
}

// MARK: - Where the mark lands

/// The press wash and the resume mark are one rectangle drawn by two different things.
///
/// ``ChannelListView/resumeMark(isResumable:)`` is a `listRowBackground`, handed the whole row
/// cell. The press wash is a `background` behind the row's `Button`, so it is only ever that
/// button's size. They agree now because the **button** was made the mark's rectangle: the cell
/// insets stop at the highlight and the label's own padding carries the content the rest of the
/// way in.
///
/// The attempt before this one gave the button a `Shape` returning a path larger than its rect.
/// A render test proved that path really is drawn — `.background` does not clip — and the rows
/// still did not match on the device, because a `List` lays its row content inside a container
/// inset by `listRowInsets` and *that* clips. **A drawing can escape its background; it cannot
/// escape the cell.** Hence a layout fix rather than a drawing one, and hence these assertions
/// are about the arithmetic rather than about a path.
@Suite("Sidebar row mark")
struct SidebarRowMarkTests {
    @Test("the cell's inset is the mark's own, so the button is the mark's rectangle")
    func theButtonIsTheMark() {
        // This is the whole fix in two lines: what the `List` insets the row by is exactly what
        // `resumeMark` insets itself by, so the button the wash sits behind occupies precisely
        // the rectangle the mark draws.
        #expect(SidebarRowMetrics.rowInsets.leading == SidebarRowMetrics.insetH)
        #expect(SidebarRowMetrics.rowInsets.trailing == SidebarRowMetrics.insetH)
        #expect(SidebarRowMetrics.rowInsets.top == SidebarRowMetrics.insetV)
        #expect(SidebarRowMetrics.rowInsets.bottom == SidebarRowMetrics.insetV)
    }

    @Test("splitting the inset did not move the row's content")
    func theSplitSumsToWhereTheContentAlwaysWas() {
        // The half that makes this a spacing fix rather than a layout change: a reader should
        // see the highlight move and the row itself stay exactly where it was.
        #expect(
            SidebarRowMetrics.rowInsets.leading + SidebarRowMetrics.labelPaddingH
                == SidebarRowMetrics.contentInsetH
        )
        #expect(
            SidebarRowMetrics.rowInsets.top + SidebarRowMetrics.labelPaddingV
                == SidebarRowMetrics.contentInsetV
        )
        // And the padding has to be real, or the wash is flush against the glyphs again.
        #expect(SidebarRowMetrics.labelPaddingH > 0)
        #expect(SidebarRowMetrics.labelPaddingV > 0)
    }

    @Test("the press is dimmer than the mark it now shares a rectangle with")
    func sharingAShapeMakesTheStrengthsMatterMore() {
        // These were always one hue at two strengths. Now that they are also the same rectangle,
        // the opacity is the *only* thing left telling a press apart from the conversation you
        // were last in — so the inequality that was a preference elsewhere is load-bearing here.
        #expect(PressFeedback.pressedFill < SidebarRowMetrics.opacity)
        // The hue itself moved off the accent in #151: both are now `PressFeedback.fillColor`,
        // a neutral white that reads as dim grey over any theme's ground. Asserted as *not* the
        // accent rather than as white, because the regression this guards is a later hand
        // re-tinting the wash — which would put the place mark back in competition with
        // whichever accent the reader has chosen, on the one surface where they share a shape.
        #expect(PressFeedback.fillColor != Color.hiveAccent)
    }

    @Test("the empty-section line keeps the content position, not the highlight's")
    func aRowThatIsNotAButtonIsNotIndented() {
        // It draws no highlight and has no label padding to add, so it has to be inset the whole
        // way itself — otherwise splitting the row insets would have shifted it 8pt outward.
        #expect(SidebarRowMetrics.contentInsets.leading == SidebarRowMetrics.contentInsetH)
        #expect(SidebarRowMetrics.contentInsets.top == SidebarRowMetrics.contentInsetV)
    }
}

// MARK: - The activity row's share of the same idea

/// The activity list had the opposite defect from the sidebar's, and it is worth keeping the
/// two beside each other: the sidebar's highlight was **misplaced**, and this one was **absent**.
///
/// All of an activity row's spacing used to be `listRowInsets`, applied to the cell *outside*
/// the `Button`. That put the content where it belonged and left the press wash nothing of its
/// own to fill — ``PressTreatment`` draws in the button's frame, and the button's frame was
/// exactly the content — so the highlight ended flush against the avatar and the text. The
/// owner's word was that it needed *some spacing in its area*.
///
/// The fix is a split, not a move, and that is the only thing worth asserting: the content has
/// to land exactly where it always did, or a spacing fix has quietly become a layout change.
@Suite("Activity row metrics")
struct ActivityRowMetricsTests {
    @Test("splitting the inset did not move the content")
    func theSplitSumsToWhereTheContentAlwaysWas() {
        // The cell's inset carries the row as far as the highlight; the button's padding
        // carries it the rest of the way. Their sum is the whole spacing, unchanged.
        #expect(
            ActivityRowMetrics.rowInsets.leading + ActivityRowMetrics.labelPaddingH
                == ActivityRowMetrics.contentInsetH
        )
        #expect(
            ActivityRowMetrics.rowInsets.top + ActivityRowMetrics.labelPaddingV
                == ActivityRowMetrics.contentInsetV
        )
        // Symmetric, because a row that is 16 from one edge and 15 from the other is a defect
        // nobody looks for.
        #expect(ActivityRowMetrics.rowInsets.leading == ActivityRowMetrics.rowInsets.trailing)
        #expect(ActivityRowMetrics.rowInsets.top == ActivityRowMetrics.rowInsets.bottom)
    }

    @Test("the highlight has room of its own, at both ends")
    func theWashIsNeitherFlushNorSwallowingTheGap() {
        // The defect being fixed: zero padding meant the wash touched the glyphs.
        #expect(ActivityRowMetrics.labelPaddingH > 0)
        #expect(ActivityRowMetrics.labelPaddingV > 0)
        // And the failure the fix could have introduced instead — taking *all* of the cell's
        // inset would leave two neighbouring highlights with nothing between them.
        #expect(ActivityRowMetrics.rowInsets.top > 0)
        #expect(ActivityRowMetrics.rowInsets.leading > 0)
    }

    @Test("an activity row's highlight is the same distance from the edge as the sidebar's mark")
    func thisListAndTheSidebarAgreeAcross() {
        // The one number shared with the other list, and shared on purpose: a pressed activity
        // row and a marked sidebar row sit the same distance from the same screen edge, so the
        // two tabs do not read as two apps. The vertical is deliberately *not* shared — these
        // rows are three lines tall, and the sidebar's 1pt would put two highlights together.
        #expect(ActivityRowMetrics.highlightInsetH == SidebarRowMetrics.insetH)
        #expect(ActivityRowMetrics.highlightInsetV > SidebarRowMetrics.insetV)
    }
}
