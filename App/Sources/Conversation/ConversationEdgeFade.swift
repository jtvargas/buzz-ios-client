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
/// Re-measured 2026-09-09 when the owner asked whether it could simply be switched on: in a
/// probe holding both arrangements, glyph-edge energy **1,400px down the screen** — nowhere near
/// an edge — is `0.19` with the effect on the flipped list against `13.14` on the unflipped
/// oracle. The whole list is smeared to 1.4% of its legibility, so this stays off.
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
/// # What it is made of, and why it is a stack rather than one pane
///
/// The system effect ramps the blur *radius*: at the very edge a glyph is dissolved into the
/// ground, and a few points in it is merely soft. One material cannot do that — its radius is
/// fixed, so masking it fades the blur's *strength* only, which lowers a glyph's contrast while
/// leaving its edges exactly where they were. Measured against the system effect on an unflipped
/// oracle in the same probe, same ruler content, that is the whole of the difference the owner
/// reported: mean horizontal glyph-edge energy in the outer 30pt of the band was **1.30 where
/// the system gives 0.68**, and **3.43 against 1.89** in the band under the navigation bar. Text
/// that stays sharp and merely dims reads as a grey wash laid over the conversation rather than
/// as an edge.
///
/// So the blur is three `.ultraThinMaterial` bands stacked, each masked to a shorter span than
/// the one beneath it. Every material samples through the ones already drawn, so the number of
/// blurs a pixel has been through rises towards the edge — that compounding *is* the radius
/// ramp. Same measurement, stacked: **0.82 / 1.44 / 2.43** against the system's
/// **0.68 / 1.23 / 1.89**.
///
/// # Why the materials are darkened
///
/// A material in dark mode is a translucent white, so every layer lifts a near-black ground —
/// three of them took it from 13 to 33 where the system effect leaves it at 13, and that lift is
/// the other half of the wash. `brightness` is an *offset* rather than a scale, so it takes the
/// lift back out without scaling the blurred text with it; a colour scrim strong enough to do
/// the same job dims the text as well and puts the wash straight back.
///
/// The offset is tuned against the darkest ground and is safe on the lightest of the fifteen: an
/// alpha composite over a dark ground lifts by `alpha × (1 - ground)`, which varies by ~11%
/// across `#000000`…`#222222`, so the band can sit at most ~3/255 *below* a light theme's ground
/// rather than above it.
///
/// The thin colour ramp left over carries the last of the content into the ground, in
/// ``HiveTheme/background``, so this follows the reader's theme like every other ground in the
/// app.
struct ConversationEdgeFades: ViewModifier {
    /// How far past the navigation bar the fade keeps going. Short: the fade's job is the band
    /// the bar covers, and a long tail reads as the screen being dirty rather than as an edge.
    ///
    /// `36` rather than the `30` this shipped with. The stack recovers to full sharpness sooner
    /// than the single masked pane did, and six more points is what puts the recovery back on
    /// the system effect's.
    private static let topReach: CGFloat = 36

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

    /// How many materials are stacked. Layer `i` covers `1 - i/3` of the band, so the spans are
    /// the whole band, two thirds, one third.
    ///
    /// Three: two leaves a legible step where the second mask ends, and four costs another
    /// full-band backdrop sample for a difference the measurement cannot see — 2.44 against
    /// 2.43 in the band under the bar.
    private static let layers = 3

    /// The fraction of each layer's span spent fading that layer out. Half: shorter and the
    /// stack's own steps read as bands, longer and the outer layers are too faint at the edge to
    /// compound into anything.
    private static let feather: Double = 0.5

    /// The brightness offset every material carries. See this type's note on why they are
    /// darkened at all.
    private static let darken: Double = -0.115

    /// The colour tail's peak — `0.22` where the single-pane version needed `0.80`, because the
    /// stack does the covering now and this only carries the last of it into the ground.
    private static let scrim: Double = 0.22

    /// The tail's falloff, as the share of ``scrim`` still covered at each stop.
    ///
    /// Not a two-stop `LinearGradient`: a straight ramp puts its half-way point in the middle of
    /// the band, which reads as a wash with a visible top and bottom rather than as an edge.
    /// This is the curve that shipped, unchanged; only its peak moved.
    private static let falloff: [(location: CGFloat, share: Double)] = [
        (0.00, 1.00),
        (0.42, 0.95),
        (0.62, 0.71),
        (0.80, 0.34),
        (1.00, 0.00),
    ]

    var body: some View {
        ZStack {
            ForEach(0 ..< Self.layers, id: \.self) { index in
                let span = 1 - Double(index) / Double(Self.layers)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .brightness(Self.darken)
                    // Masked rather than faded with `opacity`: the material has to thin out
                    // across its span, not go transparent as a uniformly blurred pane.
                    .mask { layer(to: span) }
            }
            ramp(of: theme.background)
        }
    }

    /// One layer's mask — solid to `span × (1 - feather)`, gone by `span`.
    private func layer(to span: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: max(0, span * (1 - Self.feather))),
                .init(color: .clear, location: span),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The colour tail, under the reader's own ground, so what passes under the bar goes the
    /// colour of the screen rather than the colour of a scrim.
    private func ramp(of colour: Color) -> LinearGradient {
        LinearGradient(
            stops: Self.falloff.map {
                .init(color: colour.opacity(Self.scrim * $0.share), location: $0.location)
            },
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
