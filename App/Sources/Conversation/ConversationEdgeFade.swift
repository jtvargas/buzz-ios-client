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
/// luminance fell from **89 to 25** over a ground of 20, and contrast across the list from
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
/// It is applied *before* `safeAreaBar`, so the composer draws on top of it rather than being
/// dimmed by it. The bars — navigation above, composer below — render outside the flip and were
/// never the problem.
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
    /// The composer's measured height, so the bottom fade covers exactly what the composer
    /// floats over. Passed in rather than measured again here: ``ConversationScaffold`` already
    /// reads it for the accessory and the dismissal band, and a second reading of the same bar
    /// is a second chance for the two to disagree.
    let barHeight: CGFloat

    /// How far past the navigation bar the top fade keeps going. Short: the fade's job is the
    /// band the bar covers, and a long tail reads as the screen being dirty rather than as an
    /// edge.
    private static let topReach: CGFloat = 30
    /// The same for the composer, a little tighter — the composer is already inset 12pt from
    /// each side, so the fade shows in those gutters at full length and wants less of it.
    private static let bottomReach: CGFloat = 22

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
            // # The bottom: anchored, because the inset there is the keyboard
            //
            // No reading, deliberately. `safeAreaInsets.bottom` is the home indicator until the
            // keyboard comes up and then it is the keyboard, and a fade sized off that is a
            // 400pt wash the moment somebody types. This aligns to the safe-area bottom instead
            // — which is where `safeAreaBar` puts the composer's own bottom, keyboard or not —
            // so the band is the composer plus a tail in *both* states and the arithmetic that
            // could get it wrong does not exist.
            //
            // It is also the rule this shell states at the top of the file: nothing in here
            // reads a keyboard height. The strip below the safe area is left bare on purpose;
            // the composer insets the scrollable content, so no message ever scrolls into it.
            .overlay(alignment: .bottom) {
                ConversationEdgeFade(edge: .bottom)
                    .frame(height: barHeight + Self.bottomReach)
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

    var body: some View {
        ZStack {
            // The blur. Masked rather than faded with `opacity`, so the material itself thins
            // out across the band instead of a uniformly blurred pane going transparent.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask { ramp(of: .black) }
            // The recede. Under the reader's own ground, so what passes under the bar goes the
            // colour of the screen rather than the colour of a scrim.
            ramp(of: theme.background)
        }
    }

    /// The gradient both layers share, in whichever colour the layer needs.
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
