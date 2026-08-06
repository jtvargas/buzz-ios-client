import BuzzKit
import SwiftUI

/// The trailing toolbar item on the home screen: your own face, with the connection
/// state as a dot on it, opening the account sheet.
///
/// # It says what the pill said
///
/// This replaces a text pill that read `Connecting` / `Live` / `Paused` / `Offline`
/// beside a separate account button. The fact is unchanged — the dot's colour is the
/// engine's state, not the presence roster — but it is now carried by the picture it is
/// about, in the same bottom-trailing corner a conversation row puts a person's presence
/// dot. Two toolbar items became one: a face and a `person.crop.circle` beside it were
/// two ways to say *you*, and the word `Live` beside them was a status with no subject.
///
/// # Why the colour is the engine and not presence
///
/// Presence is a fact about a person, and this device's own heartbeat is a poor thing to
/// report back to its owner — it says "yes, you are here", which the person holding the
/// phone already knows. The interesting fact at this corner of the screen is whether the
/// app is connected to the relay at all, which is exactly what the pill carried and what
/// stops a silent workspace being read as a quiet one.
struct AccountAvatarButton: View {
    let state: SyncEngine.State
    /// Your artwork, or `nil` for the monogram.
    let picture: URL?
    /// Your pubkey — the monogram's stable colour seed.
    let seed: String
    /// Your initials, for the monogram.
    let monogram: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AvatarView(url: picture, seed: seed, monogram: monogram, size: Self.size)
                .overlay(alignment: .bottomTrailing) { dot }
                .padding(8)
        }
        // The picture already supplies its own artwork. The wash lands behind an opaque
        // avatar and is rarely the part anyone sees; what answers the finger here is the
        // shrink, and naming the shape is what stops the state dot's corner catching a
        // rounded-rectangle edge on the one frame the picture has not loaded.
        .buttonStyle(.hivePress(.control, in: PointyHexagon()))
        .glassEffect(.regular.interactive(), in: PointyHexagon())
        .accessibilityLabel("Account")
        // The state rides as the control's value rather than in its label, so VoiceOver
        // says "Account, live" and the button is still found by its name.
        .accessibilityValue(Self.label(for: state))
        .accessibilityHint("Shows your account")
        .animation(.default, value: state)
    }

    /// The state dot, drawn exactly as a conversation row draws presence: the same
    /// diameter, the same ring in the surface colour so it reads as sitting on top of the
    /// picture rather than punched out of it.
    private var dot: some View {
        Circle()
            .fill(Self.color(for: state))
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Color.hiveGround, lineWidth: 1.5))
            .accessibilityHidden(true)
    }

    /// The word for a state — what the pill used to draw, now spoken rather than shown.
    static func label(for state: SyncEngine.State) -> String {
        switch state {
        case .stopped: "Offline"
        case .starting: "Connecting"
        case .running: "Live"
        case .suspended: "Paused"
        }
    }

    /// The dot's colour. Green only for a running engine; everything else is a colour
    /// that reads as "not yet" rather than as an error, because none of these states is
    /// one — a suspended engine is a backgrounded app.
    static func color(for state: SyncEngine.State) -> Color {
        switch state {
        case .stopped: .secondary
        case .starting: .orange
        case .running: .green
        case .suspended: .yellow
        }
    }

    /// Small enough for a toolbar, large enough for two initials to be legible.
    private static let size: CGFloat = 28
}
