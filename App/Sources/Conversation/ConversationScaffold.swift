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
/// # Why there is no header slot here
///
/// There was one, and it is gone: the heading is the navigation bar's own leading item now
/// (``ConversationTitleBar``), so the top of this shell is the system bar's to inset and the
/// system bar's to blur under. That also returns the real back button and the interactive
/// drag-back, which the app-drawn row cost. `barHeight` is measured from the bottom bar's
/// geometry alone and is only ever used to lift the accessory off it, and keyboard avoidance
/// is a bottom-edge inset, so nothing here double-counts with the bar above.
///
/// # What must not be added
///
/// No `ignoresSafeArea(.keyboard)`, no keyboard-height observer, no second bottom
/// inset, and no `ToolbarItem(placement: .keyboard)` — each of those double-counts
/// with SwiftUI's own keyboard avoidance and is the mechanism behind a keyboard-sized
/// strip left behind after dismissal.
///
/// ``keyboardDismissPadding(_:)`` below is not an exception to that rule: it reads no
/// keyboard height and insets nothing. It tells UIKit that the band the bar occupies is
/// part of the dismissal gesture, which is otherwise dead until the touch reaches the
/// keyboard itself. Measured either way — see ``ConversationKeyboardDismissPadding``.
struct ConversationScaffold<Content: View, Bar: View, Accessory: View>: View {
    /// Whether the newest row is in view. The owner freezes its rendered tail while
    /// this is `false`, so an arriving message cannot move the reader's place.
    @Binding var isAtBottom: Bool
    /// Whether the newest row is far enough below to be worth offering a way back to it.
    /// A separate, wider band than the freeze's — see ``farFromBottom(_:container:)``.
    @Binding var isFarFromBottom: Bool
    /// Bumped by the owner to force a jump — an own send, or one of the affordances
    /// above the composer.
    var jumpToken: Int = 0
    /// Where that jump lands. Read when ``jumpToken`` changes, so the owner sets both
    /// before bumping.
    var jumpTarget: ConversationJumpTarget = .bottom
    /// Fired while the top of the loaded history is near. The owner must be
    /// idempotent: this can fire repeatedly across one page load.
    var onReachedTop: () -> Void = {}
    /// Fired as the surface begins leaving the screen, after the shell has handed the
    /// keyboard back. Clear whatever focus state the surface owns, so nothing is left to
    /// re-raise a keyboard for a composer that is no longer on screen.
    var onLeavingScreen: () -> Void = {}

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
    /// Where the reader is and who put them there — see ``ConversationReaderPlace`` for
    /// what it corrects and why the anchors below are not enough on their own.
    @State private var place = ConversationReaderPlace()

    /// The band that counts as *at* the bottom — releasing the owner's frozen tail.
    /// Tight, because releasing grows the content by every held row, and a
    /// bottom-anchored list preserves distance-to-bottom across that growth: release
    /// somewhere the reader is not, and their place is yanked away.
    private static var atBottomSlack: CGFloat { 8 }
    /// The band that counts as clearly *away* from the bottom — re-freezing it. Two rows
    /// of separation from ``atBottomSlack`` is the hysteresis: a single slack value of
    /// about one row height (which is what this was) put both edges inside a 3pt drag of
    /// each other, so a reader sitting just outside it could flip the state, lose the
    /// freeze, and get no re-freeze because they were still inside the band.
    private static var awayFromBottomSlack: CGFloat { 120 }
    /// The floor under the band that offers a way back to the newest message, for a
    /// viewport short enough that half of it is less than about two messages.
    private static var farFromBottomFloor: CGFloat { 240 }
    /// About a screen, so the older page lands before the reader reaches the end.
    private static var topTrigger: CGFloat { 800 }

    /// Whether the newest row is far enough below to be worth a floating control.
    ///
    /// Deliberately *not* ``awayFromBottomSlack``. That band is about one message, which
    /// is the right distance to stop moving someone's place at and far too eager for a
    /// button: it would appear the moment a reader nudged up to re-read the last thing
    /// said, and then sit on top of it. Half a viewport is the distance at which
    /// scrolling back is a journey rather than a flick, and taking it from the container
    /// rather than a constant keeps that true on an iPad and in a landscape split.
    private static func farFromBottom(_ distance: CGFloat, container: CGFloat) -> Bool {
        distance >= max(farFromBottomFloor, container / 2)
    }

    var body: some View {
        // The reader is here for one job — landing on a *particular* message, which is
        // what the "N new messages" affordance asks for. See ``jump(using:)``.
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                scroll
                // A `ZStack` child is laid out inside the safe area, so this bottom edge
                // already sits above the keyboard (or the home indicator); `barHeight`
                // lifts it clear of the composer. No inset arithmetic, no observer.
                accessory
                    .padding(.horizontal, 12)
                    .padding(.bottom, barHeight + 6)
            }
            .onChange(of: jumpToken) { jump(using: proxy) }
        }
        // The bar's own height, so the list and the composer are one drag surface: a
        // downward drag takes the keyboard from the moment it reaches the composer,
        // rather than only once it reaches the keyboard.
        .keyboardDismissPadding(barHeight)
        .releasesKeyboardWhenLeavingScreen(then: onLeavingScreen)
        // No app-drawn back swipe. Both surfaces keep the system navigation bar, so the
        // interactive pop is UIKit's own — including the drag that carries the previous
        // screen under the thumb and can be abandoned half-way, which the app's own pan
        // could not reproduce.
    }

    private var scroll: some View {
        ScrollView(.vertical) {
            content
        }
        // Innermost, and before `safeAreaBar`: this modifier binds to the *first*
        // scroll view it finds and logs a runtime issue when more than one is in the
        // hierarchy — the suggestion panel has its own. The projection is three `Bool`s
        // on purpose and never the raw distance: it keeps `Edges` cheap to compare, so
        // the action runs on a band crossing rather than on every scrolled frame.
        .onScrollGeometryChange(for: Edges.self) { geometry in
            let distance = geometry.contentSize.height - geometry.visibleRect.maxY
            return Edges(
                atBottom: distance <= Self.atBottomSlack,
                awayFromBottom: distance >= Self.awayFromBottomSlack,
                farFromBottom: Self.farFromBottom(distance, container: geometry.containerSize.height),
                nearTop: geometry.visibleRect.minY <= Self.topTrigger
            )
        } action: { _, edges in
            // Hysteresis, not a threshold: between the two bands the current state
            // stands. Release only where the newest row genuinely is, re-freeze only
            // once the reader is clearly reading something else.
            if edges.atBottom {
                if !isAtBottom { isAtBottom = true }
            } else if edges.awayFromBottom, isAtBottom {
                isAtBottom = false
            }
            // One threshold rather than a second hysteresis loop: what this decides is
            // whether a button is offered, and the crossing is animated. The bands above
            // need their gap because releasing the freeze *moves* the reader.
            //
            // Written only on a real crossing. `Edges` compares equal on most scrolled
            // frames, but `nearTop` can flip under an unchanged bottom distance, and an
            // equal write still notifies every observer of this state.
            if isFarFromBottom != edges.farFromBottom { isFarFromBottom = edges.farFromBottom }
            if edges.nearTop { onReachedTop() }
        }
        // The reader's place, restored whenever the *content* changes height under them.
        // Separate from `Edges` on purpose: that projection is three `Bool`s so it fires
        // on band crossings, and this one has to see every reading, because the distance
        // it corrects to is taken from the ones where nothing changed.
        .onScrollGeometryChange(for: ConversationReaderPlace.Span.self) { geometry in
            ConversationReaderPlace.Span(
                contentHeight: geometry.contentSize.height,
                offset: geometry.contentOffset.y,
                distance: geometry.contentSize.height - geometry.visibleRect.maxY
            )
        } action: { _, span in
            switch place.correction(for: span, atBottomSlack: Self.atBottomSlack) {
            case .none: break
            case .bottom: position.scrollTo(edge: .bottom)
            case let .offset(target): position.scrollTo(y: target)
            }
        }
        // Who is moving the list, and whether the reader has ever moved it themselves.
        // Attached beside the geometry observers so it binds to the same scroll view.
        .onScrollPhaseChange { _, phase in
            place.isScrolling = phase != .idle
            // Every phase but the one this file causes itself. Naming the reader's phases
            // instead would be a list to keep in step with the framework, and getting it
            // wrong is silent: the conversation would simply pin itself to the newest
            // message under someone reading history.
            if phase != .idle, phase != .animating { place.hasMoved = true }
        }
        .scrollPosition($position)
        // Written out per role rather than as the one-argument form, so each intent is
        // legible: open at the newest message, follow the *container* when it changes
        // (the keyboard, a growing composer), and rest a short conversation against the
        // composer. `.sizeChanges` covers content height too, and for that half it does
        // nothing at all — ``ConversationReaderPlace`` is what makes it hold, and carries
        // the measurement.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Only the message list dismisses the keyboard, and this is applied inside
        // `safeAreaBar` so the bar's own scroll views do not inherit the mode.
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            bar
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    barHeight = height
                }
        }
    }

    /// Performs the jump the owner just asked for.
    ///
    /// # Why two mechanisms for one scroll
    ///
    /// `ScrollPosition` takes the bottom edge, which is what an own send and `↓ Latest`
    /// want, and it is the same object the list's position is bound to.
    ///
    /// It cannot take a *message*, though — not here. `scrollTo(id:anchor:)` reaches the
    /// right row, but its `anchor` argument loses to `defaultScrollAnchor(.bottom, for:
    /// .alignment)` above: measured in a harness against this file, `anchor: .top` landed
    /// the target hard against the *bottom* edge, with everything the pill had just
    /// announced still below the fold — the same place the reader was already looking.
    /// Dropping the `.alignment` anchor to fix it is not a trade worth making: that is
    /// what rests a short conversation against the composer instead of under the
    /// navigation bar.
    ///
    /// A `ScrollViewReader`'s proxy honours the anchor in the same hierarchy, so the two
    /// jumps take the two paths, and each takes the one it is good at.
    private func jump(using proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.2)) {
            switch jumpTarget {
            case .bottom:
                position.scrollTo(edge: .bottom)
            case let .message(id):
                // Anchored at the top, so the first thing under the reader's eye is the
                // first message they have not read; a target too near the end of the
                // content simply lands as far as the scroll view can go, which is the
                // bottom — and the bottom is where that message is anyway.
                proxy.scrollTo(id, anchor: .top)
                // Landing on a message is the reader choosing a place that is not the
                // newest one, exactly as a drag is. Without this, the next content change
                // would put them back at the bottom they deliberately left.
                place.hasMoved = true
            }
        }
    }

    /// The bands the scaffold reacts to. `atBottom` and `awayFromBottom` are the two
    /// sides of one hysteresis loop and are deliberately both projected: the gap between
    /// them is the region where nothing changes.
    private struct Edges: Equatable {
        let atBottom: Bool
        let awayFromBottom: Bool
        let farFromBottom: Bool
        let nearTop: Bool
    }
}
