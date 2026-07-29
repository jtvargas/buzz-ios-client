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
///
/// # Why the model's lifecycle is not here
///
/// It used to be: `.task { await model.run() }` hung off the `Group` below. SwiftUI
/// distributes a modifier applied to a `Group` to that group's *children*, and this
/// group's only child is the `if let` — which is nil until somebody is typing. So the
/// group had no children, the task had nothing to attach to, and `run()` — the only
/// consumer of ``BuzzKit/PresenceStore/typing(in:thread:)`` — never started. The strip
/// could then never appear, because the only thing that could fill the model was gated
/// on content only that thing produces. Measured, not inferred: the same `.task` fires
/// on a group whose child is present and on any always-present container.
///
/// Attaching it to an always-present container here would fix the task and cost 8pt in
/// the accessory stack this sits in, every time another accessory is up. So the surface
/// that *owns* the model runs it, beside `presence.run()` — which is what every other
/// model in the app already does.
struct TypingIndicatorView: View {
    /// Owned by the conversation surface, which also drives its ``ChannelTypingModel/run()``.
    /// A `let` rather than `@State` for that reason: `State(wrappedValue:)` keeps the
    /// *first* instance it is handed and silently ignores later ones, which for a view
    /// that does not own its object is a stale reference waiting to happen.
    let model: ChannelTypingModel
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
                // Trailing, by the owner's call. It used to sit at the leading edge on the
                // argument that it annotates text starting there; in practice it lands on
                // top of the newest message's own first words, which are the ones being
                // read. At this edge it covers the ragged right instead.
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
            }
        }
        .animation(.default, value: model.typers)
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
