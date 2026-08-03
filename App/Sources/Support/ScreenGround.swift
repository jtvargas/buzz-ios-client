import SwiftUI

extension View {
    /// **The app's one dark, under a screen that would otherwise take the system's.**
    ///
    /// Every full-height surface in Hive says this: the sidebar, the conversation, Threads,
    /// Later, Drafts and Activity. **Nothing presented says it** — a sheet says
    /// ``hiveSheetGround()`` or, if it is a grouped `List`, says nothing at all. That split is
    /// the point of both, and #124 shipped without it. The colour here is
    /// ``ShapeStyle/hiveNight``, the ground the honeycomb composites over and the dark end of
    /// `LaunchBackground` — so the launch screen, the first-run hero and every screen after
    /// them are one colour rather than a set of near-blacks that are almost the same.
    ///
    /// Both halves are needed and each alone is a bug. `scrollContentBackground(.hidden)`
    /// clears the scrolling surface's *own* background, which is what lets the colour behind
    /// it reach the screen; without it a `List` paints `systemBackground` over the whole
    /// scrolling area and only the safe-area edges take the new colour.
    ///
    /// A `List` needs a third thing this cannot supply: `listRowBackground(Color.clear)` on
    /// its rows. A row is not the list, and one given no background of its own falls back to
    /// `systemBackground` — so the ground shows in the gaps and every row is an opaque black
    /// band over it. That has to be said at the row, which is why it is not folded in here.
    func hiveScreenGround() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.hiveNight)
    }

    /// **The ground under a surface that is presented rather than entered** — for the ones
    /// that scroll something other than a `List`.
    ///
    /// The same two halves as ``hiveScreenGround()``; the colour is the difference, and it is
    /// the whole point. `systemGroupedBackground` is *dynamic*, and UIKit resolves it one step
    /// lighter for a modally presented controller — `UIUserInterfaceLevel.elevated`. In this
    /// app, which is dark always, that is `#1C1C1E` where the base level is `#000000`. A modal
    /// sits visibly above the screen it covers without either of them naming a colour for the
    /// occasion.
    ///
    /// ``ShapeStyle/hiveNight`` cannot do that. It is one fixed value, so a sheet wearing it
    /// is the same near-black as the screen behind it and the modal reads as flat. That was
    /// the regression in #124, which swept `hiveScreenGround()` across full screens — right —
    /// and over the sheets with them, deleting exactly this colour from ``AccountView``.
    ///
    /// # Why a *grouped* `List` in a sheet says nothing at all instead of saying this
    ///
    /// ``ChannelDetailsView`` and ``RemindMeView`` carry no ground modifier. A grouped `List`
    /// draws its own page *and* the cards on it, and it resolves both through the UIKit trait
    /// environment it is hosted in — which is where the elevated level actually lives. So the
    /// two step up together by construction, and a ground named out here can only agree with
    /// the cards by luck: name the page `#1C1C1E` while the cards resolve at the base level
    /// and the cards are `#1C1C1E` too, which is a list with no cards on it. Both of those
    /// views had no background before #124 for exactly this reason. Adding one was the defect.
    ///
    /// Say this where nothing underneath is going to do it for you: a `ScrollView` of
    /// ``AccountCard``s, which has no ground of its own, or a `.plain` list whose rows are
    /// already `listRowBackground(Color.clear)` and so have no card to fall out of step with.
    func hiveSheetGround() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
    }
}
