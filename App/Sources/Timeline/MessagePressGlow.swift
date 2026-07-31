import SwiftUI

/// The wash a message draws under itself while it is being pressed.
///
/// # Why a message gets this and a control does not
///
/// ``PressFeedbackButtonStyle`` shrinks the thing under the finger. A message must not
/// shrink: it is not a control, it is the content, and content that recoils from a touch
/// reads as an accident. What it can do is *light up* — the same thing Slack's own message
/// does, and the same thing a table row has always done — so the reader can see which
/// message the sheet that is about to appear belongs to. That matters more here than
/// anywhere else in the app, because the sheet covers the bottom of the screen and the
/// message it acts on may be the one it is covering.
///
/// # Why it bleeds
///
/// The row is drawn inside the surface's own ``MessageRowMetrics/rowLeading`` inset, so a
/// background on the row alone would be a floating rectangle 16pt short of each screen
/// edge — an inset card, which is precisely what §3 says a message is not. Bleeding back out
/// by that inset makes it a row highlight instead: full width, and gone the moment the
/// finger lifts.
enum MessagePressGlow {
    /// How far the wash reaches past the row, horizontally.
    ///
    /// The row is drawn inside the surface's own ``MessageRowMetrics/rowLeading`` inset, so
    /// this bleeds back out to the screen and then in again by
    /// ``PressFeedback/rowInset``'s horizontal — landing a pressed message on exactly the
    /// same margins as the sidebar's mark on the conversation you were last in, which is
    /// what the owner asked the whole highlight to look like.
    static let bleed = MessageRowMetrics.rowLeading - PressFeedback.rowInset.horizontal
}

extension View {
    /// Lights this message up while `isPressed`.
    ///
    /// Applied by ``TimelineRowView`` from the press it already recognises — never from a
    /// gesture added for the purpose. A separate press-down recogniser on a row inside the
    /// message list costs the list its scrolling, which is why the round that first asked
    /// for pressed feedback on a message shipped a flash on release instead.
    func messagePressGlow(_ isPressed: Bool) -> some View {
        modifier(MessagePressGlowModifier(isPressed: isPressed))
    }
}

private struct MessagePressGlowModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPressed: Bool

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: PressFeedback.cornerRadius, style: .continuous)
                .fill(PressFeedback.fillColor.opacity(isPressed ? PressFeedback.pressedFill : 0))
                .padding(.horizontal, -MessagePressGlow.bleed)
                .padding(.vertical, -MessageRowMetrics.pressBleed)
                // Scoped to the wash itself, so nothing here can reach the enclosing list
                // and animate a row arriving in a bottom-anchored scroll view.
                .animation(PressFeedback.animation(pressed: isPressed, reduceMotion: reduceMotion), value: isPressed)
                .allowsHitTesting(false)
        }
    }
}
