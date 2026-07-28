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
    /// Bumped by the owner to force a jump — an own send, or the affordance above the
    /// composer.
    var jumpToken: Int = 0
    /// Where that jump lands. Read when ``jumpToken`` changes, so the owner sets both
    /// before bumping.
    var jumpTarget: ConversationJumpTarget = .bottom
    /// Bumped by the owner whenever the content it renders changes — rows arriving, an
    /// older page inserted, a row pruned, a reaction chip appearing.
    ///
    /// This is what tells the reader's place apart from the stack re-measuring it. A
    /// `LazyVStack`'s reported height moves whenever the container does, so "the height
    /// changed" cannot stand in for "the content changed" — see ``ConversationReaderPlace``
    /// for what that cost. Over-bumping is harmless; missing a bump means a real insertion
    /// moves the reader.
    ///
    /// A plain `Int`, which the owning surface reads in its own `body` — so a bump
    /// invalidates that body, list included. Deliberate: the events behind it are
    /// user-paced (a message, a page, someone reacting), not frame-paced, and the two
    /// tricks this file's neighbours use to avoid an invalidation — a hand-written binding,
    /// reading an observable `let` inside the smallest view that needs it — are for the
    /// things that fire on every scrolled frame. This is not one of them.
    var contentRevision: Int = 0
    /// The id of the newest row the owner is rendering — the same id its `ForEach` gives that
    /// row.
    ///
    /// This is what "go to the newest message" resolves against, in place of the content's
    /// bottom edge. The edge is not a place. A `LazyVStack` sizes every row it has not
    /// measured at the average of the ones it has, so a conversation resting on a message
    /// taller than the viewport reports an extent that is largely invented — measured on
    /// iPhone 17 Pro / iOS 26, a six-reply thread holding about 2 950 points of content
    /// reported **16 019**, and a fifty-message channel **143 255**. Landing on the bottom of
    /// that number puts the reader past where the messages end, with nothing rendered, and it
    /// does not recover: sampled again five seconds later, still not one row on screen.
    ///
    /// A row id is immune to all of it, because a row is a real view with a real frame.
    ///
    /// Note what this does *not* do: the extent is still invented. It simply stops being
    /// something anything navigates by. Apple's own guidance for lazy stacks is now explicit —
    /// *"avoid using the absolute content size or content offset with lazy stacks, since these
    /// are estimated and unstable"* (WWDC26 session 321) — and the remaining reads of both in
    /// this file are the reason the surface still owns a known defect: see the note on
    /// ``ConversationReaderPlace``.
    ///
    /// `nil` only for an empty conversation, where there is no newest message to go to.
    var newestID: String?
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
    /// The height of the region above the keyboard, kept only to tell one reading from the next.
    @State private var roomAboveTheKeyboard: CGFloat = 0
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
    ///
    /// A third, wider band — half a viewport — used to be projected beside these two, for
    /// the `↓ Latest` pill. It is gone with the pill: it was the only distance this shell
    /// read that no scroll decision depended on, and the state it fed had exactly one
    /// reader (see ``ConversationJumpState/control``).
    private static var awayFromBottomSlack: CGFloat { 120 }
    /// About a screen, so the older page lands before the reader reaches the end.
    private static var topTrigger: CGFloat { 800 }

    var body: some View {
        // Every scroll this file performs goes through this proxy, because every one of them
        // names a row. There is no path left that targets a content edge — see ``newestID``.
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                scroll(using: proxy)
                // A `ZStack` child is laid out inside the safe area, so this bottom edge
                // already sits above the keyboard (or the home indicator); `barHeight`
                // lifts it clear of the composer. No inset arithmetic, no observer.
                accessory
                    .padding(.horizontal, 12)
                    .padding(.bottom, barHeight + 6)
            }
            // The same fact the accessory relies on, read as a number: this stack's height *is*
            // the room above the keyboard, so it shrinks when the keyboard comes up and is
            // untouched by anything else in this shell — the composer is inset inside the scroll
            // view, not beside this. See ``roomAboveTheKeyboardDidChange(using:)``.
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                let previous = roomAboveTheKeyboard
                roomAboveTheKeyboard = height
                if previous > 0, height != previous { roomAboveTheKeyboardDidChange(using: proxy) }
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

    private func scroll(using proxy: ScrollViewProxy) -> some View {
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
            if edges.nearTop { onReachedTop() }
        }
        // The owner's commit, ahead of the readings it produces: `onChange` runs in the
        // update pass and a scroll geometry callback runs after layout, so the window is
        // open by the time the new content has been measured.
        .onChange(of: contentRevision) { place.contentDidChange() }
        // A change of *width* is the one content change the owner cannot declare, because it
        // did not make it: every row re-wraps, so every row's height is genuinely new. A
        // rotation, an iPad split, a Slide Over.
        //
        // Width and not size: the keyboard moves the container's height on every raise, and
        // treating that as a content change is the whole defect ``ConversationReaderPlace``
        // documents. Measured on iPhone 17 Pro / iOS 26, portrait → landscape → portrait with
        // a reader parked in history: without this they came back seven messages adrift
        // (rows 1042–1045 → 1035–1036, distance-to-bottom 3281 → 8086); with it they come
        // back where they were.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width
        } action: { _, _ in
            place.contentDidChange()
        }
        // The reader's place, carried across the settling that follows a commit — and
        // deliberately *not* across a height change with no commit behind it, which is the
        // stack re-measuring rows nobody touched.
        //
        // Separate from `Edges` on purpose: that projection is three `Bool`s so it fires
        // on band crossings, and this one has to see every reading, because the distance
        // it corrects to is taken from the ones where nothing changed.
        .onScrollGeometryChange(for: ConversationReaderPlace.Span.self) { Self.span($0) } action: { _, span in
            apply(place.correction(for: span, atBottomSlack: Self.atBottomSlack), using: proxy)
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
        // Two roles, not three. `.initialOffset` opens the conversation at its newest
        // message; `.alignment` rests a short one against the composer instead of hanging it
        // under the navigation bar.
        //
        // `.sizeChanges` is deliberately absent, and its removal is the other half of this
        // change. It resolves against `contentSize.height`, so on a `LazyVStack` it followed
        // an extent that inflates every time the keyboard takes height from the viewport and
        // rows that left it revert to estimates — straight past the end of the real content.
        // Measured across thirteen thread and channel shapes on iPhone 17 Pro / iOS 26
        // (`~/.buzz/.scratch/scrollharness`, `FocusTests`): opening a conversation, touching
        // nothing and tapping the composer failed twenty assertions with this anchor present
        // and one with it removed, and the two shapes that came to rest with no message row
        // on screen at all both stop doing so.
        //
        // What it was there for is now done by the two corrections above — one for a declared
        // content change, one for the keyboard taking room at the bottom — both of which land on
        // a row instead of an edge.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Only the message list dismisses the keyboard, and this is applied inside
        // `safeAreaBar` so the bar's own scroll views do not inherit the mode.
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            bar
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    barHeight = height
                }
        }
    }

    /// The keyboard came up or went away.
    ///
    /// Points came off the bottom of the scrollable region, and nothing in this shell puts them
    /// back: `defaultScrollAnchor(.bottom, for: .sizeChanges)` is the modifier that would, and it
    /// is deliberately absent for the reason written where it used to be. So the message being
    /// replied to slides under the composer the moment it is tapped — the owner's report.
    ///
    /// Most conversations never need this: a scroll view resting *against* its bottom has its
    /// `contentOffset` clamped up when an inset takes room there, so the content follows for
    /// free. The ones that do not are those whose content landed *after* the first layout, which
    /// is how every real thread in this app opens — and which is why the report was "weird". The
    /// measurements are with the decision, in
    /// ``ConversationReaderPlace/keyboardRoomDidChange(isAtBottom:)``, along with the rule: land
    /// on the newest row when that is where the reader is, and leave a reader in history exactly
    /// where they are — the owner's own scope, *"if the user has scrolled up at all, no push"*.
    ///
    /// # Why this reads a view that is not the scroll view
    ///
    /// Because reading the scroll view's own bottom inset was built first, and it **hangs the
    /// app**. One `onScrollGeometryChange(for:)` over `containerSize.height` and
    /// `contentInsets.bottom` covers this in a single callback and passed the whole eight-shape
    /// focus suite — a keyboard is one change. But a `scrollTo` issued from inside a
    /// scroll-geometry callback re-enters layout, so a *stream* of changes does not survive it:
    /// driven by a composer growing under typing, both tests died on the first `typeText`, runner
    /// killed for being unresponsive.
    ///
    /// So the trigger is the height of the `ZStack` in ``body`` — the room above the keyboard by
    /// construction, the same fact the accessory's placement already relies on. An ordinary layout
    /// reading of a view that is not the scroll view, so a scroll issued from it cannot come back
    /// around. The first reading is skipped: that is the view being measured at all, and the
    /// opening position belongs to the `.initialOffset` anchor, which re-pinning would race.
    ///
    /// # What is not wired to this, and why
    ///
    /// The composer growing under a long draft takes room off the same edge and wants the same
    /// decision — the other half of the owner's report — and is **not** connected here. Measured
    /// across all eight shapes on iPhone 17 Pro / iOS 26 against a composer that grows 61 points,
    /// seven move the newest message 59 points unaided, for the clamping reason above; the eighth,
    /// `thread-8-longlast-primed`, moves 0. Wiring the bar's geometry here fixed that shape and
    /// then killed the growth suite as unresponsive — twice, at the same point, with 42% RAM free
    /// and no crash report on either side. Two identical failures is where this stops being an
    /// implementation detail: the diagnosis is open, and the shipped surface is what it was.
    private func roomAboveTheKeyboardDidChange(using proxy: ScrollViewProxy) {
        apply(place.keyboardRoomDidChange(isAtBottom: isAtBottom), using: proxy)
    }

    /// The three numbers ``ConversationReaderPlace`` reads, taken from one layout so they
    /// cannot disagree with each other.
    private static func span(_ geometry: ScrollGeometry) -> ConversationReaderPlace.Span {
        ConversationReaderPlace.Span(
            contentHeight: geometry.contentSize.height,
            offset: geometry.contentOffset.y,
            distance: geometry.contentSize.height - geometry.visibleRect.maxY
        )
    }

    /// Carries out what one geometry reading implied.
    ///
    /// Split out from the observer that produces it only so ``scroll(using:)`` stays inside the
    /// project's function-length rule; the two belong together.
    private func apply(_ correction: ConversationReaderPlace.Correction, using proxy: ScrollViewProxy) {
        switch correction {
        case .none:
            break
        case .bottom:
            // The newest *row*, never the content's bottom edge. The edge is what put the
            // reader past the end of a largely invented extent, with nothing rendered and no
            // recovery — see ``newestID``.
            if let newestID { proxy.scrollTo(newestID, anchor: .bottom) }
        case let .offset(target):
            position.scrollTo(y: target)
        }
    }

    /// Performs the jump the owner just asked for.
    ///
    /// # Why both destinations are rows
    ///
    /// They used to be a row and an edge: a particular message went through this proxy, and
    /// "the newest message" went to `ScrollPosition`'s bottom edge. The edge half is gone,
    /// because it resolves against `contentSize.height` — see ``newestID`` for what that
    /// number is worth here. Anything aimed at the newest message — an own send, and the
    /// `↓ Latest` pill that used to offer the trip — could land the reader past the end of
    /// the content with nothing on screen, and did.
    ///
    /// The asymmetry that remains is real and is why this takes the proxy rather than
    /// `ScrollPosition`: the proxy honours its `anchor` argument in this hierarchy, whereas
    /// `ScrollPosition.scrollTo(id:anchor:)` loses the anchor to
    /// `defaultScrollAnchor(.bottom, for: .alignment)` below — measured, `anchor: .top` landed
    /// the target hard against the bottom edge with everything the pill had just announced
    /// still below the fold. The `.alignment` anchor earns its place, so the proxy is the path
    /// that works alongside it.
    private func jump(using proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.2)) {
            switch jumpTarget {
            case .bottom:
                // Anchored at the bottom, which is where a conversation rests anyway. Nothing
                // here reads the extent.
                if let newestID { proxy.scrollTo(newestID, anchor: .bottom) }
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
        let nearTop: Bool
    }
}
