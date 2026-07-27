import SwiftUI

/// Which screens on the channel list's stack are read without the tab bar — and why that
/// is decided by the view owning the stack rather than by the screens themselves.
///
/// # The complaint
///
/// "When I navigate to a screen that doesn't show the bottom tab bar and when I get back I
/// don't want that jumping transition while appearing the bottom tab bar."
///
/// # What the jump actually is
///
/// Each of ``ChannelTimelineView`` and ``ThreadView`` used to carry its own
/// `.toolbar(.hidden, for: .tabBar)`. Measured on a standalone probe reproducing this exact
/// structure — `TabView` → `Tab` → `NavigationStack` → `List`, pushing a conversation-shaped
/// detail carrying a `safeAreaBar` — with `onGeometryChange` reading the home list's bottom
/// safe-area inset, de-duplicated at 0.5pt, and a UI test reading the trace back off the
/// accessibility tree. (Read back rather than printed: an app-side `print` never reaches the
/// `xcodebuild` log. Recorded rather than filmed: `simctl io recordVideo` averaged 3.5fps,
/// at which a 300ms animation and an instant jump are the same one frame.)
///
/// Every number below is `millisecondsSinceLaunch:inset`:
///
/// | what                                   | trace tail                          | delta   |
/// | -------------------------------------- | ----------------------------------- | ------- |
/// | control, bar never hidden              | `208:0.0,246:83.0`                  | settles |
/// | **hidden by the pushed view** (shipped)| `…,11646:34.0,12178:83.0`           | 532ms   |
/// |                                        | `…,11389:34.0,11923:83.0`           | 534ms   |
/// |                                        | `…,12082:34.0,12610:83.0`           | 528ms   |
/// | **hidden by the stack, from the path** | `…,11327:34.0,11356:83.0`           | 29ms    |
/// |                                        | `…,11636:34.0,11670:83.0`           | 34ms    |
///
/// The 34 is the home list being revealed *by the pop* with the tab bar's 49pt inset still
/// missing — it is not laid out while it is covered, so the first time it measures itself
/// again is on the way back up. Declared on the pushed view, the correction then waits for
/// that view's modifier to be torn down: half a second with the list on screen and every row
/// 49pt low, and then they snap. Declared on the stack, the visibility change is part of the
/// same state update as the path change, so no frame is ever committed with the two
/// disagreeing. 29ms is under two frames at 60fps.
///
/// # Why the pushed views do not also keep a `.hidden` of their own
///
/// Because a descendant does not win, which is the opposite of what "belt and braces" would
/// assume. The probe ran a stack declaring `.visible` with the pushed detail declaring
/// `.hidden`, and read the tab bar off the accessibility tree while the detail was on
/// screen: `tabBars=1 activity=true`. The bar stayed, under the composer. The same read
/// gives `tabBars=0` for the old per-view hiding and `tabBars=1` for a detail that hides
/// nothing, so the query discriminates and that result is not an artefact of asking wrong.
///
/// That is what forces `openedThread` up out of ``ThreadsView`` and into ``ChannelListView``
/// (which see). Left there, this stack would say `.visible` while a thread was open and win,
/// and a tab bar under a thread's composer is not cosmetic: it is a second bottom inset, and
/// every scroll and keyboard decision a conversation surface makes is arithmetic over that
/// inset.
///
/// A redundant `.hidden` on the pushed view *is* harmless once the stack drives it
/// (measured: `…,11551:34.0,11586:83.0`, 35ms). Both are gone anyway — a second declaration
/// that currently does nothing is the kind that later does something.
///
/// # The Threads screen is a different shape and was measured separately
///
/// Every number above was taken on the stack's **root** being revealed. A thread opened from
/// the Threads screen pops back onto a screen that is itself a pushed destination, so the
/// probe grew that shape too — root → an intermediate list that keeps the bar → a detail that
/// hides it — and instrumented the intermediate screen:
///
/// - route owned by the intermediate screen (what this app shipped):
///   `…,14077:34.0,14585:83.0` — **508ms**, the same defect.
/// - route hoisted to the view owning the stack: `…,13427:34.0,13448:83.0` — **21ms**.
///
/// Both arms asserted the bar was up on the intermediate screen and down on the detail
/// before timing anything, so neither is a measurement of a case it failed to reproduce.
///
/// # What was tried and rejected
///
/// - `safeAreaPadding` on the list, to reserve the bar's height so its return moves nothing:
///   it *adds* to the inset rather than replacing it. Readings rose by the padding and kept
///   the identical 49pt step — `263:56.0,308:139.0,11298:90.0,11816:139.0`.
/// - `.ignoresSafeArea(.container, edges: .bottom)`, on the list and then on the stack, to
///   decline the bar's inset outright: declines nothing. Same step, same timing.
///
/// Both are written down because an arm that leaves the measurement unchanged is **void**
/// rather than negative, and the two have to be told apart — otherwise a modifier that never
/// took effect reads as proof that the idea cannot work. What tells them apart here is that
/// the 49pt step is still in the trace.
enum ChannelListTabBar {
    /// The tab bar visibility the channel list's `NavigationStack` declares this pass.
    ///
    /// - Parameters:
    ///   - conversations: The pushed conversations — ``ChannelListView``'s navigation path.
    ///   - openedThread: The thread the Threads screen has open, if any. Held by
    ///     ``ChannelListView`` precisely so this function can see it.
    ///
    /// The Threads screen itself is deliberately absent: it is a list, not a reading surface
    /// with a composer, so it keeps the bar and pushing it leaves both inputs empty.
    static func visibility(conversations: [ConversationRoute], openedThread: ThreadRoute?) -> Visibility {
        conversations.isEmpty && openedThread == nil ? .visible : .hidden
    }
}
