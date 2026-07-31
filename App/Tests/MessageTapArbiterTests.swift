@testable import Hive
import Testing

/// One tap or two, and what each of them costs the other.
///
/// # Why this is a unit test at all
///
/// The wiring these rules sit in — which view sees which tap, and whether a picture's own
/// button and the row's gesture both count the same finger — can only be established by
/// driving the app, and `ConversationDoubleTapTests` does that. What *this* file holds is the
/// half that has broken twice on this surface and been reviewed through by reading both times:
/// **a single tap still runs its action.** That is the assertion that fails loudly here, on
/// the gate that runs on every pull request, rather than quietly on a device.
@MainActor
@Suite("Message tap arbitration")
struct MessageTapArbiterTests {
    /// Counts what ran. A reference so the closures handed to the arbiter can write to it,
    /// which is exactly how a real call site uses them.
    private final class Tally {
        var single = 0
        var double = 0
    }

    /// Short enough to keep the suite fast, long enough that two `tapped` calls issued back to
    /// back are inside it on any machine. The production number is
    /// ``MessageTapArbiter/doubleTapWindow`` and is deliberately not what is exercised here:
    /// these are rules, not the dial.
    private static let window = 0.05

    /// Comfortably past the window on a loaded CI runner. A flake here would read as "a tap
    /// stopped working", which is the report this file exists to make impossible to miss.
    private static let settle = 0.4

    /// Short for the same reason ``window`` is, and shorter than the sleeps above so that a
    /// test waiting out a window is never accidentally waiting out this as well.
    private static let settleWindow = 0.1

    private func arbiter() -> MessageTapArbiter {
        MessageTapArbiter(window: Self.window, settle: Self.settleWindow)
    }

    @Test("one tap runs the message's own action, once")
    func aSingleTapRuns() async throws {
        let tally = Tally()
        let taps = arbiter()

        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })
        // It has not run yet, and that is the cost of the gesture: the tap is waiting to find
        // out whether a second one is coming.
        #expect(tally.single == 0)
        #expect(taps.isWaiting)

        try await Task.sleep(for: .seconds(Self.settle))
        #expect(tally.single == 1)
        #expect(tally.double == 0)
        #expect(!taps.isWaiting)
    }

    @Test("two quick taps open the sheet, and the tapped thing never opens")
    func aDoubleTapRunsTheSheetOnly() async throws {
        let tally = Tally()
        let taps = arbiter()

        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })
        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })

        // The sheet is the answer to the second tap and arrives with it — nothing about the
        // *second* half of a double tap is waiting for anything.
        #expect(tally.double == 1)
        #expect(tally.single == 0)

        // And the first tap's action is not merely late. It is cancelled: a thread pushed
        // behind the sheet a quarter of a second after it opened is the defect this whole
        // arrangement exists to avoid.
        try await Task.sleep(for: .seconds(Self.settle))
        #expect(tally.single == 0)
        #expect(tally.double == 1)
    }

    @Test("a tap after a double tap is a single tap again")
    func theWindowDoesNotLatch() async throws {
        let tally = Tally()
        let taps = arbiter()

        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })
        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })
        try await Task.sleep(for: .seconds(Self.settle))

        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })
        try await Task.sleep(for: .seconds(Self.settle))

        #expect(tally.single == 1)
        #expect(tally.double == 1)
    }

    @Test("with no sheet to open, a tap is answered immediately")
    func noDoubleActionMeansNoWait() {
        let tally = Tally()
        let taps = arbiter()

        // The Threads screen's summaries, and a deleted message. There is no gesture to wait
        // for, so nothing waits — asserted synchronously on purpose, because "eventually" is
        // exactly what must not happen here.
        taps.tapped(single: { tally.single += 1 }, double: nil)

        #expect(tally.single == 1)
        #expect(!taps.isWaiting)
    }

    @Test("a waiting tap can be dropped without running")
    func cancelDropsTheWaitingTap() async throws {
        let tally = Tally()
        let taps = arbiter()

        taps.tapped(single: { tally.single += 1 }, double: { tally.double += 1 })
        taps.cancel()
        #expect(!taps.isWaiting)

        try await Task.sleep(for: .seconds(Self.settle))
        #expect(tally.single == 0)
        #expect(tally.double == 0)
    }

    @Test("the shipped window is short enough to be worn on every tap")
    func theWindowIsShort() {
        // Not a restatement of the constant: a bound. Every millisecond of this is paid in
        // front of opening a thread and opening a picture, on the two gestures readers make
        // most, and the owner has rejected this app for feeling delayed three times in one
        // evening. A quarter of a second is the ceiling that survived that.
        #expect(MessageTapArbiter.doubleTapWindow <= 0.25)
        // And long enough that a deliberate double tap fits inside it — 120–200ms between
        // taps is the ordinary range, so anything under that would make the gesture a knack.
        #expect(MessageTapArbiter.doubleTapWindow >= 0.2)
    }
}
