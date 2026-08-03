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
    var base: Color = .hiveNight

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
        reduceMotion || scenePhase != .active
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
    /// The onboarding ground: the dark end of `LaunchBackground`, fixed rather than adaptive.
    ///
    /// The hero is a dark screen in both appearances on purpose — an amber lattice glowing out
    /// of near-black is the whole look, and the light-mode version of it is a grey mesh on
    /// white. The one screen in the app that owns its own background.
    static var hiveNight: Color { Color(red: 0.055, green: 0.067, blue: 0.075) }

    /// What the head of a travelling pulse reaches: the accent pushed toward white so the
    /// light reads as passing *through* the line rather than as a second colour painted on it.
    static var hiveHoneyGlow: Color { Color(red: 1.0, green: 0.855, blue: 0.55) }
}

#Preview("Honeycomb") {
    HoneycombBackground()
}
