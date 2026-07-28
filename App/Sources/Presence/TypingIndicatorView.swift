import SwiftUI

/// The "X is typing…" pill that floats just above the composer.
///
/// # Why it floats rather than sits in the bar
///
/// It used to be a row inside ``ConversationScaffold``'s bottom bar, stacked above the
/// composer. That bar's height *is* the scroll view's bottom inset, so every time
/// somebody started or stopped typing the conversation was re-inset by the strip's
/// height and the reader's place moved under them — for an event they did not cause,
/// and eight seconds later it undid itself. Here it is an accessory: a `ZStack` child
/// laid out over the list and lifted clear of the bar. Nothing it does can move a
/// message.
///
/// # Why a capsule and not a line of text
///
/// It is over the conversation now rather than beside it, so it needs an edge of its own
/// to stay legible against whatever message it happens to cover — the same argument the
/// jump pill makes, at the same metrics, so the two cannot read as different kinds of
/// object when they stack.
///
/// Driven by ``ChannelTypingModel``; absent entirely when no one is typing. Names are
/// resolved by `nameFor` — the surface supplies known author names and falls back to a
/// short key.
struct TypingIndicatorView: View {
    @State var model: ChannelTypingModel
    let nameFor: (String) -> String

    var body: some View {
        Group {
            if let text = model.indicator(nameFor: nameFor) {
                HStack(spacing: 6) {
                    TypingDots()
                    Text(text)
                        .font(.hive(.caption2, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                // A floor, not a height: at an accessibility text size the label keeps
                // its intrinsic height and grows the capsule instead of being clipped
                // inside it. Same reasoning as ``NewMessagesPill``.
                .frame(minHeight: 28)
                .glassEffect(.regular, in: .capsule)
                // Leading, unlike the jump pill: this annotates the conversation's text,
                // which starts at this edge, and a centred one reads as a control.
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
            }
        }
        .animation(.default, value: model.typers)
        .task { await model.run() }
    }
}

/// The three dots, cycling.
///
/// A `PhaseAnimator` rather than a repeating `withAnimation`: it owns its own clock and
/// stops with the view, so a pill that lives eight seconds leaves no animation running
/// on a conversation that has since been popped.
///
/// Motion is the whole content here — the dots say "still going" in a way no static
/// glyph does — so with Reduce Motion on they are drawn at rest rather than swapped for
/// something else.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(lit: nil)
        } else {
            PhaseAnimator([0, 1, 2]) { phase in
                dots(lit: phase)
            } animation: { _ in
                .easeInOut(duration: 0.3)
            }
        }
    }

    /// The row of dots with one of them lit, or all of them at rest when `lit` is nil.
    private func dots(lit: Int?) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .opacity(lit == nil || lit == index ? 1 : 0.3)
            }
        }
        .accessibilityHidden(true)
    }

    /// Small enough to read as punctuation beside caption text rather than as a control.
    private static let diameter: CGFloat = 4
}
