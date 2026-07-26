import SwiftUI

/// The shared shell for every message surface — channel, thread, and DM.
///
/// # Why the composer overlays the list
///
/// The old shape was `VStack { messages; typing; composer }`, and that single
/// decision caused three of the reported defects at once. Liquid Glass renders "a
/// shape anchored behind this view filled with the physical glass material": a
/// composer laid out *beside* the list has nothing behind it to refract, so it reads
/// as the flat opaque panel JT saw, and the keyboard region — outside the `VStack`'s
/// frame — showed whatever sat behind the navigation stack instead of the
/// conversation. So the scroll view keeps full height and the bar floats over it,
/// attached with `safeAreaBar`, which insets the *scrollable content* (the last
/// message stays reachable) and registers the bar for the scroll edge effect.
///
/// # Why scroll policy lives here and content policy does not
///
/// The scaffold reports two facts — whether the newest row is in view, and when the
/// top is near — and the owning model decides what they mean. That keeps "don't yank
/// history out from under a reader" and "load the next page" testable without a view
/// host, and keeps this file free of per-surface special cases.
///
/// # What must not be added
///
/// No `ignoresSafeArea(.keyboard)`, no keyboard-height observer, no second bottom
/// inset, and no `ToolbarItem(placement: .keyboard)` — each of those double-counts
/// with SwiftUI's own keyboard avoidance and is the mechanism behind a keyboard-sized
/// strip left behind after dismissal.
struct ConversationScaffold<Content: View, Bar: View, Accessory: View>: View {
    /// Whether the newest row is in view. The owner freezes its rendered tail while
    /// this is `false`, so an arriving message cannot move the reader's place.
    @Binding var isAtBottom: Bool
    /// Bumped by the owner to force a jump to the newest row — an own send, or the
    /// "N new messages" affordance.
    var jumpToken: Int = 0
    /// Fired while the top of the loaded history is near. The owner must be
    /// idempotent: this can fire repeatedly across one page load.
    var onReachedTop: () -> Void = {}

    /// The message rows. Populated *before* first layout, or the bottom anchor
    /// resolves against an empty stack and the surface opens in the wrong place and
    /// then jumps.
    @ViewBuilder var content: Content
    /// The floating composer. Its height insets the scrollable content, nothing else.
    @ViewBuilder var bar: Bar
    /// Floats over the list just above the bar — deliberately *not* inside it, so
    /// showing mention suggestions never re-insets the message list on a keystroke.
    @ViewBuilder var accessory: Accessory

    @State private var position = ScrollPosition(idType: String.self)
    @State private var barHeight: CGFloat = 0

    /// One row of slack, so a rubber-band bounce cannot toggle `isAtBottom`.
    private static var bottomSlack: CGFloat { 64 }
    /// About a screen, so the older page lands before the reader reaches the end.
    private static var topTrigger: CGFloat { 800 }

    var body: some View {
        ZStack(alignment: .bottom) {
            scroll
            // A `ZStack` child is laid out inside the safe area, so this bottom edge
            // already sits above the keyboard (or the home indicator); `barHeight`
            // lifts it clear of the composer. No inset arithmetic, no observer.
            accessory
                .padding(.horizontal, 12)
                .padding(.bottom, barHeight + 6)
        }
    }

    private var scroll: some View {
        ScrollView(.vertical) {
            content
        }
        // Innermost, and before `safeAreaBar`: this modifier binds to the *first*
        // scroll view it finds and logs a runtime issue when more than one is in the
        // hierarchy — the suggestion panel has its own. The projection is a pair of
        // `Bool`s on purpose, so the action runs on a threshold crossing rather than
        // on every scrolled frame.
        .onScrollGeometryChange(for: Edges.self) { geometry in
            Edges(
                atBottom: geometry.contentSize.height - geometry.visibleRect.maxY <= Self.bottomSlack,
                nearTop: geometry.visibleRect.minY <= Self.topTrigger
            )
        } action: { _, edges in
            if edges.atBottom != isAtBottom { isAtBottom = edges.atBottom }
            if edges.nearTop { onReachedTop() }
        }
        .scrollPosition($position)
        // Written out per role rather than as the one-argument form, so each intent is
        // legible: open at the newest message, keep the distance to the newest message
        // when content or container size changes (an older page arriving, the keyboard,
        // a growing composer), and rest a short conversation against the composer.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Only the message list dismisses the keyboard, and this is applied inside
        // `safeAreaBar` so the bar's own scroll views do not inherit the mode.
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: jumpToken) {
            withAnimation(.smooth(duration: 0.2)) {
                position.scrollTo(edge: .bottom)
            }
        }
        .safeAreaBar(edge: .bottom) {
            bar
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    barHeight = height
                }
        }
    }

    /// The two crossings the scaffold reacts to.
    private struct Edges: Equatable {
        let atBottom: Bool
        let nearTop: Bool
    }
}

/// The "N new messages" affordance: shown when the reader has scrolled up and the
/// timeline is holding new arrivals back, so nothing moves under them until they ask.
struct NewMessagesPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .clipShape(.capsule)
        .accessibilityLabel(label)
        .accessibilityHint("Double tap to jump to the newest message")
    }

    private var label: String {
        count == 1 ? "1 new message" : "\(count) new messages"
    }
}
