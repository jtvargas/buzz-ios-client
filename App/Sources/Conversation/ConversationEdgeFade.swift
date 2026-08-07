import SwiftUI

/// **The scroll edge effect, drawn by hand, because the system one cannot run on this surface.**
///
/// # Why this file exists at all
///
/// iOS 26 gives every scroll view under a bar a progressive blur-and-fade at that edge, and
/// ``ConversationScaffold`` turns it off — `scrollEdgeEffectHidden(true, for: .all)`. That is not
/// a preference. The conversation's scroll view is flipped on the y axis
/// (``SwiftUI/View/conversationInverted()``), and the system effect composited against a flipped
/// surface does not veil an *edge*: it veils the whole thing. Measured on iPhone 17 Pro /
/// iOS 26.1 against the shipped build, same fixture, only that line changed — text peak
/// luminance fell from **255 to 25** over a ground of 20, and contrast across the list from
/// **20.4 to 1.4**, uniformly in the upper, middle and lower thirds. Uniform is the tell: an edge
/// effect that dims the middle of the list as hard as the top is not acting as an edge effect.
///
/// The flip is not negotiable — it is what holds a reader's place to within 18pt when an older
/// page arrives, where every unflipped strategy lost them by 2,500–4,800pt.
///
/// # Why this can work where the system's cannot
///
/// **Order.** The system effect is a property of the scroll view, so it is inside the flip. This
/// is an `overlay` applied *after* `conversationInverted()`, so it is not flipped: it composites
/// over the already-rendered surface, upright, sampling what is actually on screen.
///
/// It is applied *before* `safeAreaBar`, so the composer draws on top of it. Measured, not
/// assumed — see the geometry note on ``ConversationEdgeFades/body(content:)``.
///
/// # What it is made of, and why it is two layers rather than one
///
/// A plain colour gradient alone is a curtain: it hides text but does not soften it, and the
/// owner asked for *"not a solid bar… an actual soft edge that feels native"*. A material alone
/// blurs but does not recede, so text stays legible as a smear right up to the bar.
///
/// So: a material masked by the same gradient that drives the colour. The mask is what makes it
/// progressive — the blur is strongest at the edge and gone by the inner boundary — and the
/// colour underneath it carries the content the rest of the way into the ground. Neither layer
/// reaches full opacity at the very edge; at `0.94` a hint of what is passing under the bar
/// still shows through, which is the difference between a soft edge and the solid bar.
///
/// The colour is ``HiveTheme/background``, so this follows the reader's theme like every other
/// ground in the app.
struct ConversationEdgeFades: ViewModifier {
    /// The composer's measured height. Both a *length* — the band the composer covers is drawn at
    /// full cover, the way a system bar's own background is — and a *distance*, because it is how
    /// far down the bottom overlay has to be pushed to reach that band at all. Passed in rather
    /// than measured again here: ``ConversationScaffold`` already reads it for the accessory and
    /// the dismissal band, and a second reading of the same bar is a second chance for the two to
    /// disagree.
    let barHeight: CGFloat

    /// How far past the navigation bar the top fade keeps going. Short: the fade's job is the
    /// band the bar covers, and a long tail reads as the screen being dirty rather than as an
    /// edge.
    private static let topReach: CGFloat = 30
    /// The ease *above* the composer — the whole of what this fade takes from the message area.
    ///
    /// Fixed, and that is the point. It used to be `barHeight + 22`, which is the same number in
    /// the wrong role: a composer grown to four lines took 212pt of readable conversation with it
    /// and the owner reported the top *"looks okay"* and the bottom *"impossible to read"* — the
    /// asymmetry between two fades built from the same stops, one of which was sized off a bar
    /// that grows. The band below this ease scales with the composer; the ease does not.
    private static let bottomEase: CGFloat = 44
    /// How far past the composer's own bottom edge the cover keeps going.
    ///
    /// The strip between the composer and the screen bottom is the home indicator's, and the
    /// conversation scrolls through it — the owner's *"it needs to be below the composer as
    /// well"*. 60 is comfortably more than that inset on any device this app runs on, and the
    /// surplus is spent off the bottom of the screen. With the keyboard up there is no strip at
    /// all (the composer sits on the keyboard) and the whole 60 is behind the keyboard, unseen.
    ///
    /// Over-reaching downward is free in a way that reading the inset is not: `safeAreaInsets`
    /// *becomes the keyboard*, and a band sized off it washes 300pt of screen the moment somebody
    /// types. Nothing in this file reads a keyboard height.
    private static let bottomOverhang: CGFloat = 60

    func body(content: Content) -> some View {
        content
            // # The top: measured, because it has to spill past an inset
            //
            // The band the fade covers is the navigation bar *and* the status bar above it, and
            // the only way to know how tall that is together is to read the inset. The reader is
            // outside `ignoresSafeArea` on purpose: it has to report the inset before the fade
            // is allowed past it. The other way round and it reads zero and the fade collapses
            // to its reach.
            //
            // Safe at the top and only at the top — this inset is the notch, and nothing the
            // reader does changes it.
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    ConversationEdgeFade(edge: .top)
                        .frame(height: proxy.safeAreaInsets.top + Self.topReach)
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)
            }
            // # The bottom: offset, because `.bottom` here is the composer's *top*
            //
            // `safeAreaBar` takes the bar's height out of the scroll view's frame, so this
            // overlay's bottom edge lands on the composer's top edge — not on the composer, and
            // not on the screen. Measured on iPhone 17 Pro / iOS 26.1 in a standalone probe of
            // this exact arrangement (`~/.buzz/.scratch/edgefadeprobe`), keyboard up: scroll
            // frame `62→418`, bar `418→556`, and the un-offset overlay `190→418`. Its bottom and
            // the bar's top are the same 418.
            //
            // That is the whole of the first attempt's defect. A band of `barHeight + 22` hung
            // off that anchor does not cover the composer — it stacks *on top of the
            // conversation*, and grows as the composer grows.
            //
            // So the band is pushed down by exactly the distance that anchor is short by. It then
            // covers what a system bar's edge effect covers: an ease into the composer's top, the
            // composer's own band at full cover, and the strip below it. The composer draws over
            // it — the same probe, sampled: the field's text is `(255,255,255)` inside the band
            // while the bar's gutter beside it takes the tint. `offset` and not a layout change,
            // so nothing in the scroll view moves for it.
            .overlay(alignment: .bottom) {
                ConversationEdgeFade(edge: .bottom, ease: Self.bottomEase)
                    .frame(height: Self.bottomEase + barHeight + Self.bottomOverhang)
                    .offset(y: barHeight + Self.bottomOverhang)
                    // Decoration, and a scroll surface: a fade that swallowed a touch would
                    // make the bottom of every conversation dead to the drag that scrolls it.
                    .allowsHitTesting(false)
            }
    }
}

/// One edge's worth of ``ConversationEdgeFades``. See there for why it is shaped like this.
private struct ConversationEdgeFade: View {
    @Environment(\.hiveTheme) private var theme

    let edge: VerticalEdge
    /// Bottom only: the length of the ease, with everything past it drawn at full cover.
    ///
    /// The top has no equivalent because its band *is* its ease — there is no bar-shaped run of
    /// full cover to draw, the navigation bar being a floating pill with the screen edge just
    /// above it. The bottom's band is mostly composer, so it is ease-then-hold.
    var ease: CGFloat?

    /// The falloff, as the fraction of the band that is still covered at each stop.
    ///
    /// Not a two-stop `LinearGradient`: a straight ramp from opaque to clear puts its half-way
    /// point in the middle of the band, which reads as a grey wash with a visible top and bottom
    /// rather than as an edge. These stops hold near-full cover across the bar itself and then
    /// ease out, which is the shape the system effect draws.
    private static let falloff: [(location: CGFloat, cover: Double)] = [
        (0.00, 0.94),
        (0.42, 0.90),
        (0.62, 0.68),
        (0.80, 0.32),
        (1.00, 0.00),
    ]

    /// The cover the band holds once the ease is done — the same value the ease starts from, so
    /// the join is invisible.
    private static var fullCover: Double { falloff[0].cover }

    var body: some View {
        if let ease {
            // Ease into the composer, then hold. Two rectangles rather than one long gradient:
            // a gradient stretched over `ease + barHeight` would put its half-way point inside
            // the composer and change shape every time the composer grew a line.
            VStack(spacing: 0) {
                layers { ramp(of: $0) }
                    .frame(height: ease)
                layers { $0.opacity(Self.fullCover) }
            }
        } else {
            layers { ramp(of: $0) }
        }
    }

    /// The blur and the recede, in that order, both driven by the same shading.
    ///
    /// The material is *masked* rather than faded with `opacity`, so it thins out across the band
    /// instead of a uniformly blurred pane going transparent. The colour goes under it, so what
    /// passes beneath the bar goes the colour of the screen rather than the colour of a scrim.
    private func layers<Shading: ShapeStyle>(_ shading: (Color) -> Shading) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask { Rectangle().fill(shading(.black)) }
            Rectangle()
                .fill(shading(theme.background))
        }
    }

    /// The gradient both layers share, in whichever colour the layer needs. Runs from the screen
    /// edge inward, so the bottom's is upside down relative to the top's.
    private func ramp(of colour: Color) -> LinearGradient {
        LinearGradient(
            stops: Self.falloff.map { .init(color: colour.opacity($0.cover), location: $0.location) },
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }
}

extension View {
    /// Draws ``ConversationEdgeFades`` at the top and bottom of this surface.
    ///
    /// Say it after ``SwiftUI/View/conversationInverted()`` and before `safeAreaBar`. Both halves
    /// of that are load-bearing and the reasons are in ``ConversationEdgeFades``.
    func conversationEdgeFades(barHeight: CGFloat) -> some View {
        modifier(ConversationEdgeFades(barHeight: barHeight))
    }
}
