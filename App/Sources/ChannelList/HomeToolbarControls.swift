import BuzzKit
import SwiftUI

/// The home screen's trailing toolbar item: your history, and your face, in one capsule.
///
/// # Why one item and not two
///
/// The owner's reference is a single glass capsule holding both controls, which is what
/// iOS draws for itself when two toolbar items sit side by side. It is not what this can
/// use: the pair has to *fade* as the communities panel comes out — the whole bar belongs
/// to the sidebar, and the panel covers the sidebar — and the toolbar's own shared
/// background is drawn behind the items rather than by them, so an `.opacity` on the
/// content leaves an empty capsule hanging over the panel. Drawing the capsule here puts
/// the glass inside the thing that fades.
///
/// So ``ChannelListView`` keeps `sharedBackgroundVisibility(.hidden)` for the reason it
/// always had — the toolbar must not draw a background of its own behind this — and the
/// shape it hides is now a capsule around two controls rather than a hexagon around one.
///
/// # The glass is not interactive
///
/// `.interactive()` would answer a press on either control by lighting the whole capsule,
/// which says "you pressed this pair" when the reader pressed one of two things. Each
/// button already answers for itself, in its own circle, through ``PressFeedback``.
///
/// # The history is not opened from here
///
/// This button owns a flag and nothing else. The list it shows is drawn by the sidebar, as
/// part of the sidebar — see ``RecentPlacesPanel`` for the crashes that came of presenting
/// it from a toolbar item instead. A toolbar item is the single worst place in this app to
/// hang a presentation off: it is rebuilt by every message, heartbeat and profile that
/// lands.
struct HomeToolbarControls: View {
    /// Whether the history is on screen. Owned by the screen that draws it.
    @Binding var showsHistory: Bool
    /// The shared resolver, for your picture and your initials.
    let names: EntityNames
    /// The engine's state, drawn as the dot on your face.
    let state: SyncEngine.State
    /// Your pubkey — your picture, your initials, and the monogram's colour seed.
    let selfPubkey: String
    let openAccount: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            historyButton
            AccountAvatarButton(
                state: state,
                picture: names.picture(for: selfPubkey),
                seed: selfPubkey,
                monogram: names.initials(for: selfPubkey),
                action: openAccount
            )
        }
        .glassEffect(.regular, in: .capsule)
    }

    private var historyButton: some View {
        Button {
            // A toggle rather than a set, so the control that opened the panel is also the
            // one that closes it — pressing it again while it is up is the gesture anyone
            // tries first, and the scrim below the toolbar cannot catch that press.
            showsHistory.toggle()
        } label: {
            Image(systemName: Self.symbol)
                .font(.hiveSymbol(fixedSize: Self.glyphPointSize, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .padding(8)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .accessibilityLabel("History")
        .accessibilityHint("Shows the places you visited recently")
    }

    /// The clock with the arrow running back around it, at the owner's word. Named here
    /// rather than at the call site because a misspelt system symbol renders as *nothing* —
    /// no warning, no placeholder — and one constant is what a test can assert exists.
    static let symbol = "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted"

    /// The size ``AccountAvatarButton`` draws its picture at, so the two controls are the
    /// same size inside the capsule and the pair is symmetrical about its middle.
    private static let controlSize: CGFloat = 28
    /// The glyph is drawn smaller than the control it sits in, at the owner's word: a face
    /// fills its circle and a line drawing at the same size reads heavier than one.
    private static let glyphPointSize: CGFloat = 17
}
