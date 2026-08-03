import SwiftUI

extension View {
    /// **The app's one dark, under a screen that would otherwise take the system's.**
    ///
    /// Every full-height surface in Hive says this: the sidebar, the conversation, Threads,
    /// Later, Drafts, Activity, Account, Settings and the two grouped sheets. The colour is
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
}
