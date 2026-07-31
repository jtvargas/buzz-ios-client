import XCTest

/// That a finger can still scroll the conversation.
///
/// # Why this exists
///
/// Every other assertion in this suite moves the conversation *programmatically* — by
/// sending, by focusing the composer, by jumping — and then reads where the rows landed.
/// None of them drags. So when a gesture attached to a message row began claiming the touch
/// at touch-down, the whole suite stayed green while the message list could not be scrolled
/// by hand at all: the one input every reader uses first was the one input nothing tested.
///
/// The rule this file exists to hold: **anything a message row observes about a finger must
/// leave the scroll view's own pan alone.** A gesture that reports touch-down on a row inside
/// a scrolling list is the specific construction that breaks it, and it breaks it silently —
/// the row lights up correctly while the list underneath goes dead.
final class ConversationDragScrollTests: ConversationScrollHarness {
    /// How far the drag travels, as a fraction of the window. Long enough that no plausible
    /// rubber-band or bounce accounts for the movement asserted below.
    private static let dragSpan: CGFloat = 0.45

    /// What counts as having scrolled. A row that moved less than this did not scroll — it
    /// settled, or the list bounced.
    private static let moved: CGFloat = 50

    /// How long to let a tap's own consequences finish before reading the screen.
    ///
    /// `PressFeedback.minimumVisible` (the deferral the row's tap now waits out so its
    /// highlight is seen) plus the navigation push. Written here rather than imported because
    /// a UI test target drives the app as a black box and shares no symbols with it — so if
    /// that constant is ever raised, this is the line that has to move with it.
    private static let settle: TimeInterval = 0.9

    func testADragBeginningOnAMessageScrollsTheConversation() throws {
        let app = launch(["-fixtureConversation", "channel", "-messages=40"])

        let before = rendered(app)
        let anchor = try XCTUnwrap(before.dropLast().last, "no message row to drag from")

        // The drag BEGINS on a message row, deliberately: a drag begun on empty space would
        // still scroll a list whose rows are eating every touch, which is exactly the defect
        // this asserts against.
        drag(app, fromY: anchor.frame.midY)

        let after = rendered(app)
        guard let landed = after.first(where: { $0.index == anchor.index }) else {
            // The row scrolled off the screen entirely. That is a scroll.
            return
        }
        XCTAssertGreaterThan(
            abs(landed.frame.minY - anchor.frame.minY),
            Self.moved,
            """
            message \(anchor.index) sat at \(Int(anchor.frame.minY)) before a \
            \(Int(Self.dragSpan * 100))% drag and \(Int(landed.frame.minY)) after — the \
            conversation did not scroll under the finger
            """
        )
    }

    /// The same claim through the reader's own eyes: older messages come into view.
    ///
    /// Separate from the frame assertion above because the two fail differently — a list
    /// that rubber-bands moves rows without revealing anything, and a list pinned to the
    /// bottom reveals nothing while its rows move.
    func testDraggingDownRevealsOlderMessages() throws {
        let app = launch(["-fixtureConversation", "channel", "-messages=40"])

        let oldestBefore = try XCTUnwrap(rendered(app).map(\.index).min(), "nothing rendered")
        drag(app, fromY: try XCTUnwrap(rendered(app).dropLast().last).frame.midY)
        let oldestAfter = try XCTUnwrap(rendered(app).map(\.index).min(), "nothing rendered after the drag")

        XCTAssertLessThan(
            oldestAfter,
            oldestBefore,
            "the oldest message on screen was \(oldestBefore) before the drag and \(oldestAfter) after — "
                + "dragging down did not reach back into history"
        )
    }

    /// The same claim on the other surface.
    ///
    /// Not redundant: the reporter attaches to whichever scroll view encloses it, and the two
    /// surfaces build that scroll view separately. The rest of this suite carries eight
    /// shapes across both for exactly that reason — a conversation that scrolls in a channel
    /// and not in a thread is a shape this repo has shipped before.
    func testADragScrollsAThreadToo() throws {
        let app = launch(["-fixtureConversation", "thread", "-messages=40"])

        let anchor = try XCTUnwrap(rendered(app).dropLast().last, "no reply to drag from")
        drag(app, fromY: anchor.frame.midY)

        let after = rendered(app)
        guard let landed = after.first(where: { $0.index == anchor.index }) else { return }
        XCTAssertGreaterThan(
            abs(landed.frame.minY - anchor.frame.minY),
            Self.moved,
            "reply \(anchor.index) did not move under a \(Int(Self.dragSpan * 100))% drag — the thread did not scroll"
        )
    }

    /// The other half of the same rule: observing the press must not eat the tap either.
    ///
    /// The gesture that killed the scroll killed this too — a message could be pressed and
    /// lit and still not open, which is a row that looks alive and is not. Asserted through
    /// the push rather than through a spy, because "the handler ran" and "the thread opened"
    /// came apart here once already.
    func testTappingAMessageOpensItsThread() throws {
        let app = launch(["-fixtureConversation", "channel", "-messages=40"])

        let target = try XCTUnwrap(readable(app).dropLast().last, "no message row to tap")
        let window = app.windows.firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX, dy: target.frame.midY))
            .tap()

        // The row's tap is *deliberately* deferred — the press has to be visible before the
        // screen it is drawn on is replaced — and the push then animates. Reading the
        // hierarchy during that is not a slower answer, it is a wrong question: ``rendered``
        // enumerates every static text by index, and a row leaving between the count and the
        // fetch fails the enumeration itself ("No matches found for Element at index 6").
        // So: let the transition happen, then poll at an interval rather than in a spin.
        Thread.sleep(forTimeInterval: Self.settle)

        // The fixture's messages carry no replies, so the thread this opens holds exactly one
        // message: the opener that was tapped. That makes the push observable in the same
        // reading the rest of this suite uses, with nothing added to the app to see it.
        let deadline = Date().addingTimeInterval(8)
        var shown: [Int] = []
        while Date() < deadline {
            shown = rendered(app).map(\.index)
            if shown == [target.index] { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail(
            "tapped message \(target.index) and the screen still shows \(shown) — the thread did not open"
        )
    }

    // MARK: - Driving

    /// Drags downward from `fromY`, the way a thumb reaches back into history.
    ///
    /// `press(forDuration:thenDragTo:)` rather than `swipeDown()`: a swipe is issued as a
    /// flick with no press phase, and the construction under test only misbehaves once a
    /// touch has been held long enough for a row's own gesture to claim it. The hold is what
    /// makes this a regression test rather than a coincidence.
    private func drag(_ app: XCUIApplication, fromY: CGFloat) {
        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: window.midX, dy: fromY))
        let end = origin.withOffset(CGVector(dx: window.midX, dy: fromY + window.height * Self.dragSpan))
        start.press(forDuration: 0.15, thenDragTo: end)
    }
}
