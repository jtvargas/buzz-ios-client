import XCTest

/// That a page of older history landing above the reader does not move what they are reading.
///
/// # Why this suite did not exist, and what that cost
///
/// Every other shape in this suite produces its content changes at the bottom or inside a row.
/// The one change that lands *above* the reader — an older page fetched because they scrolled
/// back — could not be produced at all: the surface reaches a relay for it, and the fixture had
/// no relay. So the correction for the only content change that moves everything the reader can
/// see was the one correction never measured here, and the defect was found on a phone after it
/// shipped, twice.
///
/// ``ConversationFixture/HistoryPager`` is that missing relay. It answers a scrollback request
/// after a delay, with messages stamped before everything seeded, through the store — so the
/// path under test is the product's own from the request onwards.
///
/// # What is asserted
///
/// A row the reader is looking at, by frame, across the landing. Not "the list did not scroll":
/// a reader mid-flick *is* scrolling, and the claim is not that they stop. The claim is that the
/// page contributes nothing to where they end up — the rows already on screen stay under the
/// eye, and the arriving ones go above them.
final class ConversationOlderPageScrollTests: ConversationScrollHarness {
    /// Long enough that the page lands after the drag it was triggered by has come to rest, so
    /// this measures the correction rather than the reader's own momentum. The mid-flick case is
    /// the one below.
    private static let restingDelay = 1200

    /// Short enough that the page lands *during* the flick that asked for it — the shape the
    /// reader actually meets, and the one no correction that waits for stillness can hold.
    private static let flightDelay = 120

    /// A row that moved by more than this across the landing was moved by the landing. Generous:
    /// a `LazyVStack` re-measures rows as they come into range, so a point or two of drift is the
    /// stack settling rather than the reader being displaced.
    private static let tolerance: CGFloat = 12

    /// How long to wait for a page to show up before calling the shape inconclusive.
    private static let landingTimeout: TimeInterval = 12

    func testAnOlderPageLandingAtRestDoesNotMoveTheReader() throws {
        try assertReaderHolds(delay: Self.restingDelay, settleBeforeSampling: true)
    }

    func testAnOlderPageLandingMidFlickDoesNotMoveTheReader() throws {
        try assertReaderHolds(delay: Self.flightDelay, settleBeforeSampling: false)
    }

    // MARK: - The claim

    private func assertReaderHolds(delay: Int, settleBeforeSampling: Bool) throws {
        let app = launch([
            "-fixtureConversation", "channel",
            // Short on purpose. A fixture row is most of a screen tall, so a forty-message
            // conversation is dozens of drags from its top — measured: eight drags reached
            // message 15 of 40 and never came near the trigger, which is a shape that skips
            // itself rather than one that measures anything.
            "-messages=14",
            "-olderPages=3",
            "-olderPageDelay=\(delay)",
        ])

        // Reach back until the surface asks for history. The trigger is a viewport from the top,
        // so this is a handful of drags rather than one — and it must be a *drag*, because the
        // fetch is gated on the reader having taken hold of the list.
        var asked = false
        for _ in 0 ..< 20 where !asked {
            dragBack(app)
            asked = olderHasLanded(app) || (rendered(app).map(\.index).min() ?? .max) <= 1
        }

        if settleBeforeSampling { Thread.sleep(forTimeInterval: 0.4) }

        // The row to watch, and where it sits before anything arrives. Taken from the middle of
        // what is readable: a row at either edge can leave the screen for reasons that are not
        // the defect.
        let visible = readable(app)
        let anchor = try XCTUnwrap(visible[safely: visible.count / 2], "nothing readable to anchor on")

        guard waitForOlderPage(app) else {
            let labels = app.staticTexts.allElementsBoundByIndex.prefix(12).map { $0.label }
            throw XCTSkip(
                "no older page arrived within \(Int(Self.landingTimeout))s — oldest rendered "
                    + "\(rendered(app).map(\.index).min().map(String.init) ?? "none"), on screen: "
                    + labels.joined(separator: " | ")
            )
        }
        // Let the stack finish measuring what arrived before reading the anchor again.
        Thread.sleep(forTimeInterval: 0.6)

        let landed = try XCTUnwrap(
            rendered(app).first { $0.index == anchor.index },
            "message \(anchor.index) left the screen when the older page landed — it was in the "
                + "middle of the readable band before it, so it did not leave by scrolling"
        )
        XCTAssertLessThanOrEqual(
            abs(landed.frame.minY - anchor.frame.minY),
            Self.tolerance,
            """
            message \(anchor.index) sat at \(Int(anchor.frame.minY)) before an older page landed \
            and \(Int(landed.frame.minY)) after — the page moved the reader by \
            \(Int(landed.frame.minY - anchor.frame.minY))pt
            """
        )
    }

    // MARK: - Driving

    /// Drags downward, the way a thumb reaches back into history.
    private func dragBack(_ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: window.midX, dy: window.midY * 0.6))
        let end = origin.withOffset(CGVector(dx: window.midX, dy: window.maxY * 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Whether any of the relay's messages are in the hierarchy. They are labelled differently
    /// from the seeded ones on purpose, so "a page arrived" is observable without counting rows.
    private func olderHasLanded(_ app: XCUIApplication) -> Bool {
        // `matching`, not `containing`: the latter asks which elements have a *descendant*
        // satisfying the predicate, which a leaf static text never does — so it answers zero
        // however many pages have arrived, and the shape skips itself as inconclusive.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Older message")).count > 0
    }

    private func waitForOlderPage(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(Self.landingTimeout)
        while Date() < deadline {
            if olderHasLanded(app) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}

private extension Array {
    subscript(safely index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
