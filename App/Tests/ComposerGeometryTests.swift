@testable import Hive
import Testing
import UIKit

/// The composer's growth band, and the one UIKit assumption it rests on.
///
/// ``TokenTextView`` keeps `isScrollEnabled == true` permanently so a drag that starts
/// in the composer is claimed by the composer rather than by the enclosing message
/// list. That makes the height clamp the *only* thing standing between a one-line
/// composer and a scrollable slab, so both halves are pinned here: the arithmetic
/// purely, and the measurement it consumes against a real `UITextView` in the
/// permanently-scrollable configuration.
@MainActor
@Suite("Composer geometry", .timeLimit(.minutes(1)))
struct ComposerGeometryTests {
    private static let lineHeight: CGFloat = 20
    private static let chrome: CGFloat = 18

    private func clamped(_ measured: CGFloat) -> CGFloat {
        TokenTextView.clampedHeight(
            measured: measured,
            lineHeight: Self.lineHeight,
            chrome: Self.chrome
        )
    }

    @Test("clamps to one line at the floor and six lines at the ceiling")
    func sixLineBand() {
        let floor = Self.lineHeight + Self.chrome
        let ceiling = Self.lineHeight * TokenTextView.maxVisibleLines + Self.chrome
        #expect(TokenTextView.maxVisibleLines == 6)
        #expect(floor == 38)
        #expect(ceiling == 138)

        // Below the floor (an empty text view can measure short) still reserves a line.
        #expect(clamped(0) == floor)
        #expect(clamped(floor - 1) == floor)
        // Inside the band the measurement passes through unchanged, so the composer
        // grows a line at a time rather than in steps of its own.
        for lines in 1 ... 6 {
            let exact = Self.lineHeight * CGFloat(lines) + Self.chrome
            #expect(clamped(exact) == exact)
        }
        // Past six lines the height stops and the text view scrolls instead.
        #expect(clamped(ceiling + 1) == ceiling)
        #expect(clamped(ceiling * 4) == ceiling)
    }

    @Test("a permanently scrollable text view still measures its content")
    func measuresWhileScrollable() throws {
        // The exact configuration `makeUIView` builds, minus the SwiftUI host.
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = UIEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never

        let width: CGFloat = 300
        let proposal = CGSize(width: width, height: .greatestFiniteMagnitude)
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let chrome = view.textContainerInset.top + view.textContainerInset.bottom

        view.text = "one line"
        let single = view.sizeThatFits(proposal).height
        // `sizeThatFits` measures the laid-out text, not the (still zero) bounds — the
        // assumption the pure clamp is fed with. If this ever regresses, the fallback
        // is to measure through `textLayoutManager` (`ensureLayout` + `usedRect`).
        #expect(single > 0)
        #expect(abs(single - (lineHeight + chrome)) < 2)

        view.text = Array(repeating: "line", count: 12).joined(separator: "\n")
        let many = view.sizeThatFits(proposal).height
        #expect(many > single)
        // Twelve lines measure past the ceiling, so the clamp is what stops the bar.
        let ceiling = TokenTextView.clampedHeight(
            measured: many,
            lineHeight: lineHeight,
            chrome: chrome
        )
        #expect(ceiling < many)
        #expect(abs(ceiling - (lineHeight * TokenTextView.maxVisibleLines + chrome)) < 0.01)
    }
}
