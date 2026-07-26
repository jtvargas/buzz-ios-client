import SwiftUI

/// The conversation's own header row: three floating Liquid Glass capsules over the
/// messages — the back chevron alone in a circle, the conversation's pill, and a group of
/// quiet glyphs at the trailing edge.
///
/// # Why the app draws this instead of using the navigation bar
///
/// The heading has now been in three places, and the reference client settles it. A
/// `ToolbarItem` cannot hold a two-line pill: a navigation bar is 44pt and compresses the
/// item rather than truncating the text in it, which is the "little bubble" this started as.
/// Putting the pill in its own row *under* an empty system bar fixed legibility and cost a
/// second row of chrome — about 100pt before the first message — which the owner rejected.
/// The reference does neither: it hides the system bar and draws the back button, the
/// heading, and the trailing actions as three separate capsules on **one** row. That is why
/// it can have two lines at back-button level: the 44pt constraint belongs to the system
/// bar, and there is no system bar.
///
/// So the surfaces hide theirs (`.toolbar(.hidden, for: .navigationBar)`) and this row takes
/// its place, hosted by ``ConversationScaffold`` on the top safe area so it cannot scroll
/// away and cannot double-count with the bottom bar or the keyboard.
///
/// # What hiding the bar costs
///
/// The back *button* is ours now, so it is a real control calling `dismiss()`. The swipe-back
/// *gesture* is the expensive part: hiding the bar stops UIKit's interactive pop from
/// recognising, which was measured by driving real left-edge drags through XCUITest against a
/// bar-visible control — and which no property of the recogniser reveals. ``ConversationBackSwipe``
/// puts the swipe back, and that file carries the full measurement.
///
/// # Why the three capsules are the same height
///
/// The pill's two lines of Dynamic Type set the height and the other two match it, so the
/// number is derived at every text size rather than hard-coded for one. It is *measured*
/// rather than taken from the `HStack`: `frame(maxHeight: .infinity)` on the glyph capsules
/// makes their ideal height unbounded, and a top bar sizing itself to that ideal drew a 100pt
/// lozenge. The pill's height cannot depend on theirs in return — both lines are
/// `lineLimit(1)`, so its height is independent of the width they leave it — which is what
/// makes reading it back safe rather than a layout loop.
///
/// The scaled seed matters only for the first frame, before the measurement lands: without it
/// the glyph capsules would draw at their own content height and then snap.
struct ConversationHeaderRow<Pill: View>: View {
    /// The conversation's own capsule — a plain pill in a thread, a button in a channel.
    @ViewBuilder var pill: Pill

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredPillHeight: CGFloat?
    /// The first frame's guess, scaled so it is close at any text size. See the type comment.
    @ScaledMetric(relativeTo: .subheadline) private var seedHeight: CGFloat = 40

    private var capsuleHeight: CGFloat { measuredPillHeight ?? seedHeight }

    var body: some View {
        HStack(spacing: 8) {
            backButton
            pill
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    measuredPillHeight = height
                }
            // The pill hugs its content and stops at the width left over, so a short name
            // does not sit in an over-wide capsule and the glyph group stays pinned right.
            Spacer(minLength: 0)
            if Self.showsAccessoryGlyphs(at: dynamicTypeSize) {
                trailingGlyphs
            }
        }
        // The rows' own inset, so the header starts on the vertical line the avatars and the
        // day separators start on.
        .padding(.horizontal, MessageRowMetrics.rowLeading)
        .padding(.vertical, 4)
        // Read *before* this clamp applies, so the two rules compose: the decoration is
        // dropped on the reader's real setting, and what survives is drawn at the capped one.
        .dynamicTypeSize(...Self.maximumTypeSize)
    }

    /// Whether the decorative trailing group is drawn at `size`.
    ///
    /// It is the first thing to go, because it is the only thing here that does nothing. The
    /// row's width is fixed by the screen while its content scales, and measured at AX5 the
    /// group plus the back circle left the pill about 115pt — enough for the `#` and nothing
    /// else, which is the unreadable bubble this whole header started as. Decoration yields to
    /// the conversation's name.
    static func showsAccessoryGlyphs(at size: DynamicTypeSize) -> Bool {
        !size.isAccessibilitySize
    }

    /// The largest text size the row's content is drawn at.
    ///
    /// Height is not the constraint here — the row is ours and can be as tall as it likes — but
    /// width is, and the screen does not scale. Measured on iPhone 17 Pro: past this the name
    /// is down to a few characters however much is dropped around it, so growing further trades
    /// the name for nothing. Clamping is defensible because nothing is only here: the full name
    /// is in the details sheet the pill opens and in the VoiceOver label, and every *message*
    /// still scales without limit, which is what a reader at AX5 is actually asking for.
    /// Computed rather than stored because this type is generic over its pill, and Swift has
    /// no static storage there — the same reason ``ConversationScaffold``'s bands are computed.
    static var maximumTypeSize: DynamicTypeSize { .accessibility1 }

    /// The system bar's back button, redrawn — same glyph, same leading position, same
    /// action, in a circle of its own because the reference separates it from the heading.
    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.backward")
                .font(.subheadline.weight(.semibold))
                // Square, so the capsule the button style draws clips to a circle rather
                // than to a stadium.
                .frame(width: capsuleHeight, height: capsuleHeight)
        }
        .buttonStyle(.glass)
        .clipShape(.circle)
        .accessibilityLabel("Back")
    }

    /// Two quiet glyphs sharing a capsule, for the shape the reference has there.
    ///
    /// Deliberately **not** buttons, and deliberately hidden from VoiceOver: nothing here
    /// does anything yet, and a control that looks live and is not — or one a screen reader
    /// announces and cannot activate — is worse than a decoration. They become buttons in
    /// the same change that gives them actions.
    private var trailingGlyphs: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
            Image(systemName: "bell")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: capsuleHeight)
        .glassEffect(.regular, in: .capsule)
        .accessibilityHidden(true)
    }
}
