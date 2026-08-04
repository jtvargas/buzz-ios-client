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
/// ``ChannelListView/resumeMark`` is a `listRowBackground`, so it is handed the whole row cell
/// and insets itself from that. The press wash is a `background` *inside* the row's `Button`,
/// which ``ChannelListView/rowInsets`` has already pulled in by 16 and 2. Drawn plainly the
/// press therefore lands 8pt narrower on each side and 1pt shorter — which the owner saw
/// immediately on a device, a pressed row sitting visibly inside the marked one above it, and
/// which no review of either declaration alone could show, because **neither file is wrong on
/// its own.** That is what this suite exists for: the defect lives in the relationship.
@Suite("Sidebar row mark")
struct SidebarRowMarkTests {
    /// A row cell of no special size. The alignment is a rule about insets, so it has to hold
    /// at whatever width the sidebar is handed rather than at one measured screen.
    private static let cell = CGRect(x: 0, y: 0, width: 320, height: 64)

    @Test("the press wash lands exactly on the resume mark beside it")
    func thePressWashMatchesTheResumeMark() {
        let insets = ChannelListView.rowInsets

        // What `resumeMark` draws: its own padding, taken off the whole cell.
        let mark = Self.cell.insetBy(
            dx: ChannelListView.markInsetH,
            dy: ChannelListView.markInsetV
        )

        // What the press draws: a path measured from inside the button, which begins where
        // `rowInsets` put it — then carried back into the cell's coordinates to be comparable.
        let button = CGRect(
            x: Self.cell.minX + insets.leading,
            y: Self.cell.minY + insets.top,
            width: Self.cell.width - insets.leading - insets.trailing,
            height: Self.cell.height - insets.top - insets.bottom
        )
        let wash = ChannelListView.pressMark
            .path(in: CGRect(origin: .zero, size: button.size))
            .boundingRect
            .offsetBy(dx: button.minX, dy: button.minY)

        #expect(abs(wash.minX - mark.minX) < 0.5, "left edges: wash \(wash.minX), mark \(mark.minX)")
        #expect(abs(wash.maxX - mark.maxX) < 0.5, "right edges: wash \(wash.maxX), mark \(mark.maxX)")
        #expect(abs(wash.minY - mark.minY) < 0.5, "top edges: wash \(wash.minY), mark \(mark.minY)")
        #expect(abs(wash.maxY - mark.maxY) < 0.5, "bottom edges: wash \(wash.maxY), mark \(mark.maxY)")
    }

    @Test("the outset is derived from the two insets, not typed")
    func theOutsetIsArithmeticRatherThanALiteral() {
        // The whole point of computing it: moving `rowInsets` alone must not part them. This
        // asserts the relationship rather than today's 8 and 1, so it keeps holding after a
        // later hand changes either number.
        let insets = ChannelListView.rowInsets
        #expect(ChannelListView.pressMark.outsetH == insets.leading - ChannelListView.markInsetH)
        #expect(ChannelListView.pressMark.outsetV == insets.top - ChannelListView.markInsetV)
        // And the corner has to agree too, or the two rectangles line up and still read as
        // different shapes.
        #expect(ChannelListView.pressMark.radius == ChannelListView.markRadius)
    }

    @Test("the wash never reaches outside the row cell")
    func theOutsetOnlyGivesBackWhatTheInsetsTook() {
        // The outset draws beyond the view it is a background for, which is legal but worth
        // bounding: if it ever exceeded `rowInsets` the wash would bleed into the neighbouring
        // row, and a `List` cell is the one thing here that will not clip it back.
        let insets = ChannelListView.rowInsets
        #expect(ChannelListView.pressMark.outsetH <= insets.leading)
        #expect(ChannelListView.pressMark.outsetH >= 0)
        #expect(ChannelListView.pressMark.outsetV <= insets.top)
        #expect(ChannelListView.pressMark.outsetV >= 0)
    }

    @Test("the press is dimmer than the mark it now shares a rectangle with")
    func sharingAShapeMakesTheStrengthsMatterMore() {
        // These were always meant to be one hue at two strengths. Now that they are also the
        // same rectangle, the opacity is the *only* thing left telling a press apart from the
        // conversation you were last in — so the inequality that was a preference in
        // `PressFeedbackTests` is load-bearing here.
        #expect(PressFeedback.pressedFill < ChannelListView.markOpacity)
        #expect(PressFeedback.fillColor == Color.hiveAccent)
    }
}
