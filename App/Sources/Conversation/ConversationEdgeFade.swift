import SwiftUI

/// **The scroll edge effect, drawn by hand at the top, because the system one cannot run on this
/// surface — and drawn at the top only, because the owner asked for the bottom to go.**
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
/// # Why there is no bottom fade
///
/// There was one, over two device rounds, and the owner removed it: *"remove the bottom one, no
/// need bottom fade"*. Both attempts read as taking away conversation rather than softening an
/// edge, and the reason is the surface rather than the tuning. **The composer is not a bar the
/// conversation runs under.** It is a floating card inset from every side, `safeAreaBar` insets
/// the scrollable content by its height, and the list is flipped so the bottom is where the
/// newest message rests — the one being read. Any cover there is drawn over the line somebody is
/// mid-sentence in. At the top, the same band falls on history already read and on a navigation
/// bar the content genuinely passes beneath.
///
/// So this is asymmetric on purpose, and the asymmetry is not an omission to be tidied up later.
///
/// # Why this can work where the system's cannot
///
/// **Order.** The system effect is a property of the scroll view, so it is inside the flip. This
/// is an `overlay` applied *after* `conversationInverted()`, so it is not flipped: it composites
/// over the already-rendered surface, upright, sampling what is actually on screen.
///
/// # What it is made of, and why it is two layers rather than one
///
/// A plain colour gradient alone is a curtain: it hides text but does not soften it, and the
/// owner asked for *"not a solid bar… an actual soft edge that feels native"*. A material alone
/// blurs but does not recede, so text stays legible as a smear right up to the bar.
///
/// So: a material masked by the same gradient that drives the colour. The mask is what makes it
/// progressive — the blur is strongest at the edge and gone by the inner boundary — and the
/// colour underneath it carries the content the rest of the way into the ground.
///
/// The colour is ``HiveTheme/background``, so this follows the reader's theme like every other
/// ground in the app.
struct ConversationEdgeFades: ViewModifier {
    /// How far past the navigation bar the fade keeps going. Short: the fade's job is the band
    /// the bar covers, and a long tail reads as the screen being dirty rather than as an edge.
    private static let topReach: CGFloat = 30

    func body(content: Content) -> some View {
        content
            // # Measured, because it has to spill past an inset
            //
            // The band the fade covers is the navigation bar *and* the status bar above it, and
            // the only way to know how tall that is together is to read the inset. The reader is
            // outside `ignoresSafeArea` on purpose: it has to report the inset before the fade
            // is allowed past it. The other way round and it reads zero and the fade collapses
            // to its reach.
            //
            // Safe at the top and only at the top — this inset is the notch, and nothing the
            // reader does changes it. The bottom inset is the one that becomes the keyboard, and
            // nothing in this file reads it.
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    ConversationEdgeFade()
                        .frame(height: proxy.safeAreaInsets.top + Self.topReach)
                        .ignoresSafeArea(edges: .top)
                }
                // Decoration, and a scroll surface: a fade that swallowed a touch would make the
                // top of every conversation dead to the drag that scrolls it.
                .allowsHitTesting(false)
            }
    }
}

/// The top edge's fade. See ``ConversationEdgeFades`` for why it is shaped like this.
private struct ConversationEdgeFade: View {
    @Environment(\.hiveTheme) private var theme

    /// The falloff, as the fraction of the band that is still covered at each stop.
    ///
    /// Not a two-stop `LinearGradient`: a straight ramp from opaque to clear puts its half-way
    /// point in the middle of the band, which reads as a grey wash with a visible top and bottom
    /// rather than as an edge. These stops hold near-full cover across the bar itself and then
    /// ease out, which is the shape the system effect draws.
    ///
    /// The peak was `0.94` on the first two device rounds and is `0.80` here — the owner's *"reduce
    /// the opacity a little bit of the top fade, just a little bit"*. The shape is unchanged; every
    /// stop is the same curve scaled by 0.85. The floor is `0.00`, which is no fade at all, so
    /// there is room for one more step down if it is still too much.
    private static let falloff: [(location: CGFloat, cover: Double)] = [
        (0.00, 0.80),
        (0.42, 0.76),
        (0.62, 0.57),
        (0.80, 0.27),
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
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// Draws ``ConversationEdgeFades`` at the top of this surface.
    ///
    /// Say it after ``SwiftUI/View/conversationInverted()``, or it is flipped with the list and
    /// lands at the bottom. The reason is in ``ConversationEdgeFades``.
    func conversationEdgeFade() -> some View {
        modifier(ConversationEdgeFades())
    }
}
