import XCTest

/// That the conversation's heading survives beside the two trailing buttons.
///
/// # Why this exists
///
/// A navigation-bar item that does not fit is **not truncated — it is moved into the `…`
/// overflow menu**, so the whole heading disappears rather than the name shortening. The
/// width rule in `ConversationTitleBar` exists to stop that, and until this file the rule
/// was only ever checked as arithmetic: `MessageSurfaceTests` asserts the *number* the
/// rule produces against a cliff measured by hand once, on a bar that had nothing at its
/// trailing edge.
///
/// Adding the `person.3.fill` and the `⋮` put 96pt of buttons the other side of that
/// number, and the floor absorbs the whole charge — every phone in portrait now hands the
/// name exactly the 190pt minimum. Whether 190 still fits is not something the arithmetic
/// can answer, because the arithmetic is what is in question. So this reads the bar.
final class ConversationTitleBarTests: ConversationScrollHarness {
    /// A name long enough to break the rule if the rule is wrong. 66 characters is the
    /// length the original cliff was measured with — see `MessageSurfaceTests`.
    private static let longName = String(repeating: "channel-name-", count: 5) + "abcdefghijk"

    func testTheHeadingAndBothTrailingButtonsAllFitTheBar() throws {
        XCTAssertEqual(Self.longName.count, 76, "the name under test must stay long")
        let app = launch([
            "-fixtureConversation", "channel", "-messages=8",
            "-channelName=\(Self.longName)",
        ])

        // The heading is a Button carrying the conversation's name as its accessibility
        // label. If it were pushed into the overflow menu it would not exist here — that
        // is the failure this file is for, and it is invisible to every scroll assertion.
        let heading = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "the heading is not in the bar")
        // Named, not merely present: the fixture used to title every conversation
        // "Untitled conversation" through an empty directory, which made the long name
        // above decoration and this whole assertion vacuous.
        XCTAssertTrue(
            heading.label.hasPrefix(Self.longName),
            "the heading is not the long name under test — it reads “\(heading.label)”"
        )

        let people = app.navigationBars.buttons["People"]
        let manage = app.navigationBars.buttons["Manage channel"]
        XCTAssertTrue(people.exists, "the people button is not in the bar")
        XCTAssertTrue(manage.exists, "the manage button is not in the bar")

        // No overflow menu was needed to hold any of them. `…` appearing at all means
        // something was moved out of the bar, even if the three above still resolve.
        XCTAssertFalse(
            app.navigationBars.buttons["More"].exists,
            "the bar overflowed: something was moved into the … menu"
        )

        // And they are laid out in the order the ask named: the name, then the people
        // button, then the `⋮` at the trailing edge.
        XCTAssertLessThan(heading.frame.maxX, people.frame.minX, "the heading overlaps the people button")
        XCTAssertLessThan(people.frame.maxX, manage.frame.minX, "the people button is not left of the ⋮")

        // Two capsules, not one: the `ToolbarSpacer` between them is what keeps them from
        // fusing into a single piece of glass reading as one segmented control.
        XCTAssertGreaterThan(
            manage.frame.minX - people.frame.maxX, 4,
            "the two trailing buttons have fused into one glass capsule"
        )
    }

    func testTheThreadBarCarriesPeopleAndNoManageButton() throws {
        let app = launch(["-fixtureConversation", "thread", "-messages=8"])

        XCTAssertTrue(
            app.navigationBars.buttons["People"].waitForExistence(timeout: 5),
            "a thread has participants and must offer them"
        )
        // There is nothing about a thread to manage — no mute, no topic, no canvas — and
        // the channel it hangs off has its own `⋮`.
        XCTAssertFalse(
            app.navigationBars.buttons["Manage channel"].exists,
            "a thread offered a manage button for a thing that cannot be managed"
        )
    }
}
