import XCTest

/// The shapes, and how a shape is read off the display. Shared by every suite that drives a
/// real conversation through a real keyboard.
///
/// # Why every measurement is a row frame
///
/// The defect class is precisely that the scroll view's own numbers are wrong. A `LazyVStack`
/// estimates the height of every row it has not measured, so `contentSize` and `contentOffset`
/// are guesses — Apple's guidance for lazy stacks now says so outright — and a conversation can
/// report a content height of 143 255 points holding a few thousand. An assertion built on
/// those numbers passes while the screen is blank; that mistake is the reason three claims
/// about this bug class had to be retracted.
///
/// So nothing here reads the scroll view. Every fact comes from where the message rows actually
/// are on the display, which is the only measure that cannot be wrong about what the reader
/// sees.
///
/// # Why the readable band is not the window
///
/// A row hidden behind the keyboard is not on screen. An earlier version of this measurement
/// filtered on window bounds alone, and scored shapes as holding while every row sat under the
/// keyboard. The band below is bounded by whichever of the keyboard and the composer reaches
/// highest, taken from those elements' own frames.
///
/// # Why this is a base class and not a `struct` of helpers
///
/// `XCTAssert` needs an `XCTestCase` to attribute a failure to, and the non-vacuity check in
/// ``focusComposer(_:)`` is an assertion rather than a return value on purpose — a keyboard that
/// never rose has silently turned a whole run into a layout compared against itself. It carries
/// no `test` methods, so it contributes no cases of its own.
class ConversationScrollHarness: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - The shapes

    struct Shape {
        let name: String
        let arguments: [String]
    }

    /// A thread is loaded whole and is usually short; a channel is long and paginates. The
    /// variable that decides whether this bug class appears at all is a message taller than the
    /// viewport, and where it sits.
    static let shapes: [Shape] = [
        Shape(name: "thread-8-longlast", arguments: thread(messages: 8, longLines: 60)),
        Shape(name: "thread-8-longmid", arguments: thread(messages: 8, longLines: 60, longFromEnd: 4)),
        Shape(name: "thread-8-longopener", arguments: thread(messages: 8, longLines: 60, longFromEnd: 8)),
        Shape(name: "thread-12-longlast", arguments: thread(messages: 12, longLines: 60)),
        Shape(name: "thread-8-plain", arguments: thread(messages: 8)),
        // The thread as it really opens: the opener alone from the store, the replies a relay
        // round trip later. This is the shape behind the "channels open blank" report in #49.
        Shape(name: "thread-8-longlast-primed", arguments: thread(messages: 8, longLines: 60, primed: 1)),
        Shape(name: "channel-50-longlast", arguments: channel(messages: 50, longLines: 60)),
        Shape(name: "channel-50-plain", arguments: channel(messages: 50)),
    ]

    private static func thread(
        messages: Int,
        longLines: Int = 0,
        longFromEnd: Int = 1,
        primed: Int? = nil
    ) -> [String] {
        arguments(surface: "thread", messages: messages, longLines: longLines, longFromEnd: longFromEnd, primed: primed)
    }

    private static func channel(messages: Int, longLines: Int = 0) -> [String] {
        // `-spread` widens the range of ordinary row heights, which is what decides how wrong
        // the stack's average is for the rows it has not measured.
        arguments(surface: "channel", messages: messages, longLines: longLines, longFromEnd: 1, primed: nil)
            + ["-spread"]
    }

    private static func arguments(
        surface: String,
        messages: Int,
        longLines: Int,
        longFromEnd: Int,
        primed: Int?
    ) -> [String] {
        var arguments = ["-fixtureConversation", surface, "-messages=\(messages)"]
        if longLines > 0 {
            arguments.append("-longLines=\(longLines)")
            arguments.append("-longFromEnd=\(longFromEnd)")
        }
        if let primed { arguments.append("-primed=\(primed)") }
        return arguments
    }

    // MARK: - Reading the screen

    struct Row {
        let index: Int
        let frame: CGRect
    }

    func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertFalse(
            app.otherElements["fixtureFailure"].exists || app.staticTexts["fixtureFailure"].exists,
            "the fixture could not build its conversation"
        )
        // The first messages have to be on screen before anything is measured, or the suite is
        // racing the store rather than testing the surface.
        XCTAssertTrue(
            firstRowAppears(in: app),
            "no message row ever appeared — the fixture seeded nothing, or the surface did not render it"
        )
        return app
    }

    private func firstRowAppears(in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !rendered(app).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Every fixture message the surface has rendered, on screen or not.
    ///
    /// Matched on the content the fixture wrote rather than on an accessibility identifier
    /// added for the test: the rows under test are the shipping rows, and asking them to carry
    /// a test-only marker is how the thing you measure stops being the thing you ship.
    func rendered(_ app: XCUIApplication) -> [Row] {
        app.staticTexts.allElementsBoundByIndex.compactMap { element in
            let label = element.label
            guard label.hasPrefix("Message ") else { return nil }
            let digits = label.dropFirst("Message ".count).prefix { $0.isNumber }
            guard let index = Int(digits) else { return nil }
            return Row(index: index, frame: element.frame)
        }.sorted { $0.index < $1.index }
    }

    /// The band a reader can actually read: below the navigation bar, above whichever of the
    /// keyboard and the composer reaches highest.
    ///
    /// The composer is not one element. Its text field is the top of it while the bar carries
    /// text alone, and an attached picture puts a strip *above* that field — so a band bounded
    /// by the field would count the rows behind the pictures as readable, which is the whole
    /// question ``ComposerGrowthTests`` asks. Both are measured, and the highest wins.
    func readableBand(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        var bottom = window.maxY
        let keyboard = app.keyboards.element
        if keyboard.exists, keyboard.frame.height > 0 {
            bottom = min(bottom, keyboard.frame.minY)
        }
        for field in app.textViews.allElementsBoundByIndex where field.frame.height > 0 {
            bottom = min(bottom, field.frame.minY)
        }
        let tiles = app.otherElements.matching(identifier: ComposerLabel.tile)
        for tile in tiles.allElementsBoundByIndex where tile.frame.height > 0 {
            bottom = min(bottom, tile.frame.minY)
        }
        return CGRect(x: window.minX, y: window.minY, width: window.width, height: max(0, bottom - window.minY))
    }

    func readable(_ app: XCUIApplication) -> [Row] {
        let band = readableBand(app)
        return rendered(app).filter { row in
            row.frame.height > 0 && row.frame.maxY > band.minY && row.frame.minY < band.maxY
        }
    }

    func describe(_ app: XCUIApplication) -> String {
        let band = readableBand(app)
        let shown = readable(app).map { "m\($0.index)@\(Int($0.frame.minY))h\(Int($0.frame.height))" }
        return "readable=\(Int(band.minY))..\(Int(band.maxY)) shown=[\(shown.joined(separator: " "))]"
    }

    // MARK: - Driving the composer

    /// Focuses the composer and returns how much room the keyboard took from the readable
    /// band.
    ///
    /// Measured as the band's own shrink rather than `app.keyboards.element.frame.height`. Those
    /// two disagree — 311 against 243 on iOS 26, because the reported keyboard element excludes
    /// the bar above the keys — and the number that matters here is how far the content is
    /// *entitled* to move, which is the inset the surface actually received.
    @discardableResult
    func focusComposer(_ app: XCUIApplication) -> CGFloat {
        let before = readableBand(app).height
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no composer field on screen")
        field.tap()
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 5),
            "no software keyboard — on a simulator, disable I/O > Keyboard > Connect Hardware Keyboard"
        )
        Thread.sleep(forTimeInterval: 1.5)
        let allowance = max(0, before - readableBand(app).height)
        // The suite's own non-vacuity check, and it is not theoretical: on 2026-07-27 every
        // shape in both tests reported `allowance=0` and the run passed with 32 readings and
        // 0 failures, because the *software* keyboard never appeared. `waitForExistence`
        // above does not catch that — a keyboard element exists in the hierarchy with zero
        // height when iOS believes a hardware keyboard is attached — so every assertion held
        // by comparing a resting layout against itself.
        //
        // On a headless simulator the host-side `ConnectHardwareKeyboard` default is not
        // enough; the device carries its own:
        //
        //     xcrun simctl spawn <udid> defaults write com.apple.keyboard.preferences \
        //         AutomaticMinimizationEnabled -bool false
        //     xcrun simctl spawn <udid> defaults write com.apple.keyboard.preferences \
        //         HardwareKeyboardLastSeen -bool false
        //
        // followed by a device reboot.
        XCTAssertGreaterThan(
            allowance,
            0,
            "the keyboard took no room from the readable band, so this shape asserted nothing "
                + "— see the note here for the simulator defaults that raise a software keyboard"
        )
        return allowance
    }

}
