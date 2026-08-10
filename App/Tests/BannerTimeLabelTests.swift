import Foundation
@testable import Hive
import Testing

/// The banner's source-line time.
///
/// Worth a suite for one reason: the label it replaced was the string `"now"`, hardcoded, and
/// it was right almost always — which is exactly why nobody noticed it was a lie about the
/// one message that had been sitting unread. What is pinned here is the boundaries, because
/// the only way this regresses is a later hand deciding "under a minute" should be "under
/// five" and rounding an hour-old message back down to `now`.
@Suite("Banner time label")
struct BannerTimeLabelTests {
    private let now = Date(timeIntervalSince1970: 1_786_311_600)

    private func label(secondsAgo: TimeInterval) -> String {
        BannerTimeLabel.label(
            for: Int64(now.timeIntervalSince1970 - secondsAgo),
            relativeTo: now
        )
    }

    @Test("a message that just arrived says now")
    func freshIsNow() {
        #expect(label(secondsAgo: 0) == "now")
        #expect(label(secondsAgo: 59) == "now")
    }

    @Test("an author's clock running ahead of ours still says now")
    func futureIsNow() {
        // Not defensive. `createdAt` is the *sending* device's clock, and two phones a few
        // seconds apart is ordinary — without this the common case would read "0m ago".
        #expect(label(secondsAgo: -30) == "now")
    }

    @Test("minutes and hours count, and each boundary belongs to the coarser unit")
    func elapsedCounts() {
        #expect(label(secondsAgo: 60) == "1m ago")
        #expect(label(secondsAgo: 59 * 60) == "59m ago")
        #expect(label(secondsAgo: 3600) == "1h ago")
        #expect(label(secondsAgo: 23 * 3600) == "23h ago")
    }

    @Test("past a day it stops counting and names the time")
    func oldFallsBackToAClockTime() {
        // The count is what makes a notification legible; a three-digit hour count is not.
        let day = label(secondsAgo: 25 * 3600)
        #expect(!day.hasSuffix("ago"))
        #expect(!day.isEmpty)
    }

    @Test("the label never ticks on its own")
    func labelIsPureInItsArguments() {
        // The banner lives five seconds and has no timer behind it. This is the assertion
        // that would fail if someone reached for `Date()` inside the branches rather than
        // taking `relativeTo` — which is what makes the suite above deterministic at all.
        let first = label(secondsAgo: 600)
        let second = label(secondsAgo: 600)
        #expect(first == second)
        #expect(first == "10m ago")
    }
}
