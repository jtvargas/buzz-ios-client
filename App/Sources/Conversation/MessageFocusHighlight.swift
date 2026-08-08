import SwiftUI

/// The mark that says *this is the message you came for*, after a landing has taken the
/// reader somewhere they did not scroll to themselves.
///
/// # Why a background and nothing else
///
/// It is the only treatment that cannot move anybody. A row's height is its content's
/// height on this surface, and a `LazyVStack` sizes every row it has not measured at the
/// average of the ones it has — so a single row growing re-estimates the whole extent, and
/// the reader is moved by far more than the thing that grew. That is the reaction-chip
/// defect ``ConversationReaderPlace/rowDidChangeInPlace()`` exists to absorb, and it would
/// arrive here at the exact moment the reader has just been carried across a conversation:
/// the one moment they cannot tell a bug from the trip they asked for. A background is
/// painted behind a frame that has already been decided.
///
/// Full-bleed rather than an inset card, and deliberately: the wash's job is to be findable
/// in peripheral vision at the end of a scroll, and an inset shape reads as a selection —
/// something you have picked and could act on — rather than as an answer to *where am I*.
///
/// # Why the two halves are timed differently
///
/// In fast enough to have already happened by the time the scroll settles, out slowly enough
/// that a reader who looked away for a moment still catches it going. A symmetrical fade
/// either flashes or lingers; there is no single duration that does both jobs.
extension View {
    /// - Parameter isHighlighted: whether *this* row is the one that was landed on.
    func messageFocusHighlight(_ isHighlighted: Bool) -> some View {
        modifier(MessageFocusHighlight(isHighlighted: isHighlighted))
    }
}

private struct MessageFocusHighlight: ViewModifier {
    /// The conversation's own accent, so the mark belongs to the theme the reader picked
    /// rather than introducing a colour that appears nowhere else.
    @Environment(\.hiveTheme) private var theme

    let isHighlighted: Bool

    /// Enough to find at a glance against the app's one dark, little enough that the text
    /// on top of it is not fighting it. Unmeasured on device by design — ADR-0004 puts
    /// colour weight on the owner's pass rather than in a test.
    private static let wash: Double = 0.16
    private static let fadeIn: Double = 0.15
    private static let fadeOut: Double = 0.9

    func body(content: Content) -> some View {
        content
            // Always present at zero rather than inserted when needed: an inserted view
            // has no value to interpolate *from*, so the fade in would be a pop and the
            // fade out would need a transition to survive its own removal.
            .background(theme.accent.opacity(isHighlighted ? Self.wash : 0))
            // Scoped to this row's own flag, never ambient: an unscoped animation on a
            // message row animates row insertion, which in a conversation means every
            // arriving message slides.
            .animation(
                isHighlighted ? .easeIn(duration: Self.fadeIn) : .easeOut(duration: Self.fadeOut),
                value: isHighlighted
            )
    }
}
