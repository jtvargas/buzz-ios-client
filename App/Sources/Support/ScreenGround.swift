import SwiftUI

extension EnvironmentValues {
    /// The ground-and-accent pair the reader chose in Settings.
    ///
    /// Read by ``SwiftUI/View/hiveScreenGround()`` and by the call sites that draw the app's own
    /// colour. Defaults to ``HiveTheme/hive``, so anything hosted outside the app's root — a
    /// preview, a UI-test fixture — looks the way it always did rather than losing its ground.
    @Entry var hiveTheme: HiveTheme = .hive
}

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
    /// The colour is now the chosen theme's background rather than a constant. ``HiveTheme/hive``
    /// *is* `hiveNight`, so an install that never opens the picker is unchanged.
    ///
    /// **The sheet ground below is deliberately not themed.** It resolves
    /// `systemGroupedBackground` through the UIKit trait environment, which is what steps a modal
    /// one level lighter than the screen behind it; a themed constant there would flatten every
    /// sheet in the app — exactly the #124 regression this file's own doc comment records.
    func hiveScreenGround() -> some View {
        modifier(HiveScreenGround())
    }

    /// **The ground under a surface that is presented rather than entered** — for the ones
    /// that scroll something other than a `List`.
    ///
    /// The same two halves as ``hiveScreenGround()``; the colour is the difference, and it is
    /// the whole point. A modal has to sit visibly above the screen it covers, so this is
    /// ``HiveTheme/elevatedBackground`` — the reader's own ground, one step lighter.
    ///
    /// It used to be `systemGroupedBackground`, which UIKit resolves one level up for a
    /// modally presented controller: `#1C1C1E` where the base is `#000000`. That was right
    /// while the app had exactly one ground and it was black. It broke the moment the default
    /// ground became `#222222` (2026-08-06) — the system colour cannot see the theme, so every
    /// sheet came out *darker* than the screen behind it and the elevation read backwards.
    ///
    /// The failure to avoid in the other direction is #124's: it swept the *screen* ground
    /// across the sheets too, and `hiveNight` is one fixed value, so a modal became the same
    /// near-black as the screen and read as flat. Naming a step off the theme rather than the
    /// theme itself is what keeps both of those from happening.
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
        modifier(HiveSheetGround())
    }
}

/// The themed half of ``SwiftUI/View/hiveScreenGround()``, as a modifier because only a view can
/// read the environment — a `View` extension cannot.
///
/// The colour animates rather than cutting: a ground is the largest surface on screen, and
/// swapping it instantly reads as a flash. `animation(_:value:)` is scoped to the theme alone, so
/// the crossfade cannot leak onto anything else the ground happens to be redrawn beside.
/// # Why the colour ignores the safe area itself
///
/// `background(_:ignoresSafeAreaEdges:)` defaults to `.all`, which sounds like it covers this
/// and does not: those edges are the *container* region only. The keyboard is its own region
/// (`SafeAreaRegions.keyboard`), so a raised keyboard shrinks the ground with the layout and
/// whatever the window is showing — black — comes through in the strip behind the keys and in
/// the corners its rounded top cuts out of them. Handing the colour its own
/// `ignoresSafeArea()`, whose default region set *does* include `.keyboard`, paints the whole
/// window instead.
///
/// This moves no layout and is not the banned modifier: the ban in ``ConversationScaffold`` is
/// on the *content* ignoring the keyboard, which drops the composer behind the keys. Only the
/// painted layer ignores it here.
private struct HiveScreenGround: ViewModifier {
    @Environment(\.hiveTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { theme.background.ignoresSafeArea() }
            .animation(.easeInOut(duration: 0.35), value: theme)
    }
}

/// The themed half of ``SwiftUI/View/hiveSheetGround()``, a modifier for the same reason
/// ``HiveScreenGround`` is one: only a view can read the environment.
///
/// The colour ignores the safe area here too — a sheet gets a keyboard as often as a screen
/// does, and the strip behind the keys is the same hole. It carries no `animation`: a sheet is
/// presented over a theme change rather than living through one, and the crossfade the screen
/// ground runs would fight the presentation transition.
private struct HiveSheetGround: ViewModifier {
    @Environment(\.hiveTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { theme.elevatedBackground.ignoresSafeArea() }
    }
}
