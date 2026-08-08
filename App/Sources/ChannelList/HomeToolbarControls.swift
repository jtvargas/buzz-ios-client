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
/// # The history is a system menu
///
/// Not a popover, and nothing hand-drawn. The clock is a ``Menu``: the platform supplies
/// the dropdown, its open and close animations, its dismissal, its scrolling and its
/// material, and this file supplies only the rows. See ``RecentPlacesMenu`` for why every
/// earlier version of this was both uglier and less stable than the system's own control.
///
/// Because a menu is *built to be updated while it is open*, the history no longer has to
/// be frozen before it is shown: `history()` is read in the body like any other value, and
/// a name or a visit landing while the menu is up updates the menu in place instead of
/// tearing a presentation down mid-navigation.
struct HomeToolbarControls: View {
    /// The shared resolver, for your picture and your initials.
    let names: EntityNames
    /// The engine's state, drawn as the dot on your face.
    let state: SyncEngine.State
    /// Your pubkey — your picture, your initials, and the monogram's colour seed.
    let selfPubkey: String
    /// The history, newest first, each place under the name the app uses for it now.
    let history: () -> [RecentPlaceRow]
    /// Goes where a row asked to go.
    let openPlace: (RecentPlace) -> Void
    let openAccount: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            historyMenu
            AccountAvatarButton(
                state: state,
                picture: names.picture(for: selfPubkey),
                seed: selfPubkey,
                monogram: names.initials(for: selfPubkey),
                action: openAccount
            )
        }
        // Interactive, at the owner's word: the capsule answers a press with the material's
        // own lift. Untinted — a tint here made the one control sitting over the sidebar the
        // single coloured object on the screen, which is the opposite of the reference.
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var historyMenu: some View {
        Menu {
            RecentPlacesMenu(rows: history(), open: openPlace)
        } label: {
            Image(Self.glyph)
                // Sized rather than fonted: a template image has no text style to take a
                // point size from, so the frame *is* the point size. `scaledToFit` keeps the
                // drawing's own proportions inside it — it is very slightly wider than tall.
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: Self.glyphPointSize, height: Self.glyphPointSize)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .padding(8)
                .contentShape(.circle)
        }
        // The menu's own highlight answers the press, and the capsule's interactive glass
        // lifts under it. A `hivePress` shrink on top of both is a third answer to one
        // touch, and it is the one that does not belong to the system.
        //
        // The tint is what a `UIMenu` draws its row glyphs in, and the window sets it to
        // the theme's accent for the things that genuinely want it — the caret, the swipe
        // actions, a `Link`. A history is a list of places rather than a set of actions, so
        // its `#`, locks and faces are label-coloured here, as they are in the sidebar this
        // list is a shortcut into. Set on the menu rather than inside it: the content is
        // presented by UIKit and takes the environment from the control that opened it.
        .tint(.primary)
        .accessibilityLabel("History")
        .accessibilityHint("Shows the places you visited recently")
    }

    /// The owner's own clock, drawn with the dial dissolving into dashes behind it.
    ///
    /// An asset rather than a system symbol because this drawing is not in the library — it
    /// replaced `clock.arrow.trianglehead.clockwise.rotate.90.path.dotted`, which was the
    /// nearest thing there and not the same thing. Template-rendered, so it takes the same
    /// `.primary` the symbol did and needs no second colour rule.
    ///
    /// Named here rather than at the call site for the reason the symbol was: a name that
    /// resolves to nothing renders as *nothing* — no warning, no placeholder — and one
    /// constant is what a test can assert exists.
    static let glyph = "HistoryGlyph"

    /// The size ``AccountAvatarButton`` draws its picture at, so the two controls are the
    /// same size inside the capsule and the pair is symmetrical about its middle.
    private static let controlSize: CGFloat = 28
    /// The glyph is drawn smaller than the control it sits in, at the owner's word: a face
    /// fills its circle and a line drawing at the same size reads heavier than one.
    private static let glyphPointSize: CGFloat = 17
}
