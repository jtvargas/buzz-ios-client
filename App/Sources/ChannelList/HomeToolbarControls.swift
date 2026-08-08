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
/// # The history is a real popover
///
/// It is presented from here, by this button, as the system's own dropdown. That is the
/// owner's ask and it is also the only anchor that can be right: a popover points at the
/// control that opened it, and drawing the list anywhere else means re-deriving where that
/// control happens to be.
///
/// A popover is a hazard in a view that rebuilds — its content reaches UIKit as a
/// preference, so a content value that changes makes SwiftUI dismiss and re-present it, and
/// a toolbar item is rebuilt by every message, heartbeat and picture that lands. Nothing
/// here changes: the popover is handed one ``RecentPlacesHistory``, a class, and the rows
/// inside it are filled *before* it is presented. See that type for the full account.
struct HomeToolbarControls: View {
    /// The shared resolver, for your picture and your initials.
    let names: EntityNames
    /// The engine's state, drawn as the dot on your face.
    let state: SyncEngine.State
    /// Your pubkey — your picture, your initials, and the monogram's colour seed.
    let selfPubkey: String
    /// The history, asked for at the moment the clock is pressed. A function rather than a
    /// list, so reading it registers no dependency on the directory it resolves through.
    let history: () -> [RecentPlaceRow]
    /// Goes where a row asked to go, once the popover carrying it has gone.
    let openPlace: (RecentPlace) -> Void
    let openAccount: () -> Void

    @State private var isShowingHistory = false
    /// The popover's whole content, and the one thing it is handed. Held across rebuilds.
    @State private var places = RecentPlacesHistory()

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
        // Interactive and themed, at the owner's word. `.interactive()` lets the capsule
        // answer a press with the material's own lift, on top of the shrink each button
        // already plays for itself; the tint is the accent the chosen theme carries, so the
        // one control that sits over the sidebar's ground belongs to the theme rather than
        // being the single neutral object on a coloured screen.
        .glassEffect(.regular.tint(.hiveAccent).interactive(), in: .capsule)
    }

    private var historyButton: some View {
        Button(action: presentHistory) {
            Image(systemName: Self.symbol)
                .font(.hiveSymbol(fixedSize: Self.glyphPointSize, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .padding(8)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .accessibilityLabel("History")
        .accessibilityHint("Shows the places you visited recently")
        // Anchored to this control, arrow on top, so it hangs beneath the clock.
        // `presentationCompactAdaptation(.popover)` — said by the content — is what stops
        // iPhone adapting it into a sheet from the bottom of the screen.
        .popover(isPresented: $isShowingHistory, arrowEdge: .top) {
            RecentPlacesPanel(history: places)
        }
        // Fired by the popover's dismissal, which is the earliest moment a navigation may
        // start without racing it away — the rule ``ComposerAttachButton`` documents, and
        // the one whose absence crashed this feature.
        .onChange(of: isShowingHistory) { _, presented in
            guard !presented, let place = places.chosen else { return }
            places.chosen = nil
            openPlace(place)
        }
    }

    private func presentHistory() {
        // The same entry the sidebar's headings and the composer's `+` play, because it is
        // the same event: a disclosure opening.
        HiveHaptics.play(.disclosureToggled)
        places.chosen = nil
        // Read here rather than in the body, so the popover's content is settled before it
        // is presented and nothing about it moves while it is up.
        places.rows = history()
        isShowingHistory = true
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
