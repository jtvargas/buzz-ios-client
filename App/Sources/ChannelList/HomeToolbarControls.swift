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
struct HomeToolbarControls: View {
    /// The history, resolved against the live sidebar and the active community — asked for
    /// when the popover opens, never read while it is open. See ``history``.
    let resolvePlaces: () -> [RecentPlace]
    /// The shared resolver, for the rows' names and marks.
    let names: EntityNames
    /// The engine's state, drawn as the dot on your face.
    let state: SyncEngine.State
    /// Your pubkey — your picture, your initials, and the monogram's colour seed.
    let selfPubkey: String
    let openAccount: () -> Void
    let openPlace: (RecentPlace) -> Void

    @State private var showsHistory = false
    /// The list this popover is showing, taken once when it opens.
    ///
    /// A popover's content rides to UIKit as a preference. Changing it while the popover is
    /// presented makes SwiftUI dismiss and re-present, and *opening a place changes this very
    /// list* — the visit is recorded the moment the push lands. That dismissal then runs
    /// inside the navigation transition it caused, and UIKit traps: four crash reports off the
    /// owner's phone, all of them `UIKitPopoverBridge.dismissAndReset` inside a running
    /// transition or the navigation path underflowing beneath it. It survived only when the
    /// place tapped was already at the front, which is the one case where the list does not
    /// change.
    ///
    /// So the list is frozen for as long as it is on screen. A history that reshuffles under
    /// the finger would be wrong even if it were safe.
    @State private var history: [RecentPlace] = []
    /// The place tapped, held until the popover has gone. ``openPlace`` rewrites the
    /// navigation stack, and a push started from inside a dismissing presentation races the
    /// modal transition — the reason the sheets in this app route their navigation through
    /// `onDismiss` (see ``CreateChannelSheet``). A popover has no `onDismiss`, so the hook is
    /// its content disappearing.
    @State private var pending: RecentPlace?

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
            // Read here rather than in `body`: a value read inside an action registers no
            // dependency, so neither this button nor the popover it opens is rebuilt by a
            // visit being recorded.
            history = resolvePlaces()
            showsHistory = true
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
        // Attached to the button rather than to the capsule so the popover points at the
        // control that opened it and not at the space between two of them.
        .popover(isPresented: $showsHistory) {
            RecentPlacesPopover(places: history, names: names) { place in
                pending = place
                showsHistory = false
            }
            // Without this a popover becomes a sheet in a compact width, which on a phone
            // is every time — and a sheet is a screen, which is more than a list of twelve
            // shortcuts is worth.
            .presentationCompactAdaptation(.popover)
            // The popover's own content going away is the one moment that is provably after
            // the dismissal rather than inside it — this popover's `onDismiss`.
            .onDisappear(perform: openPending)
        }
    }

    /// Jumps to the place tapped, now that the popover holding it has gone.
    private func openPending() {
        guard let place = pending else { return }
        pending = nil
        openPlace(place)
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
