import SwiftUI

/// The animated honeycomb behind the onboarding hero — `Honeycomb.metal` driven by a clock.
///
/// The whole view is deliberately tiny and self-contained, because `TimelineView(.animation)`
/// re-evaluates its body once per displayed frame: anything inside it is rebuilt 120 times a
/// second on ProMotion. Only the shaded rectangle lives in there. The hero's text, buttons and
/// community card sit *outside* the timeline and are built once, which is the difference
/// between a shader that costs a few hundred microseconds of GPU and a screen that re-lays-out
/// its entire content every frame.
struct HoneycombBackground: View {
    /// Hexagon width in points. Large enough that the lattice reads as a pattern rather than a
    /// texture at arm's length, and large enough that a light running round one cell's outline
    /// is a stroke a reader can follow rather than a speck.
    var cellSize: CGFloat = 56

    /// The flat colour under the lattice. The pattern composites over it inside the shader.
    var base: Color = .hiveGround

    /// Whether this instance is on screen at all.
    ///
    /// The hero is the screen, so it defaults to true and never passes anything else. A
    /// caller that keeps the comb mounted behind something closed — the workspace panel sits
    /// off the leading edge until it is dragged out — has to say so: a `TimelineView` does not
    /// care that it is off-screen, and an unseen one would run the shader at 120 Hz for the
    /// life of the sidebar.
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The clock's origin. Held in state rather than derived from `context.date` directly so
    /// the shader's `time` starts near zero — a `TimeInterval` since 2001 narrowed to `Float`
    /// has about two seconds of precision, which quantises the whole animation into a stutter.
    @State private var start = Date()

    /// Reduce Motion gets the same lattice with the pulses frozen part-way round. Not a blank
    /// background: the pattern is the screen's identity, and the setting asks for less
    /// movement, not less design. The constant is picked so a few cells sit lit rather than
    /// all or none.
    private static let stillTime: Double = 4.2

    private var isPaused: Bool {
        !isAnimating || reduceMotion || scenePhase != .active
    }

    var body: some View {
        TimelineView(.animation(paused: isPaused)) { context in
            let time = reduceMotion ? Self.stillTime : context.date.timeIntervalSince(start)

            GeometryReader { proxy in
                let size = proxy.size
                Rectangle()
                    .fill(base)
                    .colorEffect(
                        ShaderLibrary.hiveHoneycomb(
                            .float2(size.width, size.height),
                            .float(time),
                            .float(cellSize),
                            .color(.hiveAccent),
                            .color(.hiveHoneyGlow)
                        )
                    )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension ShapeStyle where Self == Color {
    /// **The app's one dark**, and the dark end of `LaunchBackground` — the two are kept at the
    /// same value on purpose, so the launch screen and the first frame the app draws are the
    /// same colour and there is no flash between them.
    ///
    /// Everything that owns a ground takes this: the onboarding hero and the wizards on its
    /// comb, the communities panel, and the sidebar. They were three darks that were nearly but
    /// not quite the same, which is more visible than any of them being wrong — a reader moving
    /// between two surfaces sees the step, not the colour.
    ///
    /// Fixed rather than adaptive. An amber lattice glowing out of near-black is the whole
    /// look, and the light-mode version of it is a grey mesh on white.
    ///
    /// Not black itself: the panel's leading edge is what tells a reader it is a surface that
    /// arrived over the sidebar rather than part of it, and against pure black that edge is
    /// carried by the drop shadow alone. What separates panel from sidebar now that they share
    /// a colour is the scrim (``WorkspacePanelGeometry/scrimOpacity``), which darkens what is
    /// behind the panel by a quarter for as long as it is out.
    static var hiveNight: Color { Color(red: 0.021, green: 0.025, blue: 0.029) }

    /// What the head of a travelling pulse reaches: the accent pushed toward white so the
    /// light reads as passing *through* the line rather than as a second colour painted on it.
    static var hiveHoneyGlow: Color { Color(red: 1.0, green: 0.855, blue: 0.55) }
}

#Preview("Honeycomb") {
    HoneycombBackground()
}
