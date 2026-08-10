import SwiftUI

/// The mark for a room that will clean itself up: a clock whose ring is solid down its
/// left half and then breaks into a run of dots down its right, so the ring itself reads
/// as running out.
///
/// # Why this is drawn and not a symbol
///
/// Because there is no SF Symbol of it. `timer` has the meaning and the wrong shape;
/// `clock.arrow.trianglehead.clockwise.rotate.90.path.dotted` has the dots and an
/// arrowhead that makes it read as *history*. The glyph wanted here is Lucide's
/// `clock-fading`, which is what the Buzz desktop and Flutter clients draw
/// (`mobile/lib/features/channels/channels_page/badges.dart:67`), and drawing the same
/// mark is the whole point of the exercise.
///
/// The alternative was a custom `.symbolset`. This is a drawing instead for one reason:
/// a symbol set hand-authored without the SF Symbols app either renders or renders
/// *nothing at all*, with no warning and no missing-symbol box — the failure ``AppGlyph``
/// exists to talk about. A shape either compiles into the right geometry or is visibly
/// wrong. It keeps both properties that mattered about a symbol: it takes its colour from
/// `foregroundStyle` like any glyph, and it follows Dynamic Type, which the app's two
/// PNG glyphs silently do not.
struct EphemeralClockGlyph: View {
    @ScaledMetric private var side: CGFloat

    /// - Parameters:
    ///   - height: the glyph's edge, in points at the default text size.
    ///   - textStyle: the style it scales against — the one the text beside it uses, so
    ///     the pair grows together.
    init(height: CGFloat, relativeTo textStyle: Font.TextStyle = .footnote) {
        _side = ScaledMetric(wrappedValue: height, relativeTo: textStyle)
    }

    var body: some View {
        ZStack {
            EphemeralClockFace()
                .stroke(style: StrokeStyle(
                    lineWidth: side * EphemeralClockMetrics.stroke / EphemeralClockMetrics.box,
                    lineCap: .round,
                    lineJoin: .round
                ))
            // Filled circles rather than zero-length segments of the stroked path. Lucide
            // draws them the second way and SVG renders it, but CoreGraphics does not
            // promise a round cap on a zero-length subpath — an empty right half is not a
            // failure worth risking to save a shape.
            EphemeralClockDots()
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The ring's solid half, and the two hands.
private struct EphemeralClockFace: Shape {
    func path(in rect: CGRect) -> Path {
        let m = EphemeralClockMetrics.self
        let unit = min(rect.width, rect.height) / m.box
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * unit, y: rect.minY + p.y * unit)
        }

        var path = Path()
        // Six o'clock round to twelve, the long way through nine. Said as increasing
        // angle so it is the sweep and not the `clockwise:` flag that decides which half
        // is drawn — that flag is named for a y-up space and this one is y-down.
        path.addArc(
            center: point(m.center),
            radius: m.ringRadius * unit,
            startAngle: m.arcStart,
            endAngle: m.arcEnd,
            clockwise: false
        )
        path.move(to: point(m.hourHandTip))
        path.addLine(to: point(m.center))
        path.addLine(to: point(m.minuteHandTip))
        return path
    }
}

/// The nine dots the ring fades into.
private struct EphemeralClockDots: Shape {
    func path(in rect: CGRect) -> Path {
        let m = EphemeralClockMetrics.self
        let unit = min(rect.width, rect.height) / m.box
        let centre = CGPoint(x: rect.minX + m.center.x * unit, y: rect.minY + m.center.y * unit)
        let radius = m.stroke / 2 * unit

        var path = Path()
        for angle in m.dotAngles {
            let dot = CGPoint(
                x: centre.x + cos(angle.radians) * m.ringRadius * unit,
                y: centre.y + sin(angle.radians) * m.ringRadius * unit
            )
            path.addEllipse(in: CGRect(
                x: dot.x - radius, y: dot.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
        return path
    }
}

/// The glyph's geometry, on the 24-unit box Lucide draws `clock-fading` in.
///
/// A plain enum rather than members of the shapes: a `Shape` refines `View` and is
/// therefore `@MainActor`, so geometry declared on one cannot be read from anywhere that
/// is not.
///
/// Every number here was **measured** off the artwork rather than guessed: the ring's ink
/// on the centre row and column gives r=10 with a 2-unit stroke, and sampling the ring at
/// half-degree steps gives one unbroken arc from 85.5° to 274.5° — a 90°–270° path plus a
/// round cap at each end — and nine dots on 18° centres from −72° to +72°.
enum EphemeralClockMetrics {
    static let box: CGFloat = 24
    static let center = CGPoint(x: 12, y: 12)
    static let ringRadius: CGFloat = 10
    static let stroke: CGFloat = 2
    /// Six o'clock. Zero is three o'clock and the box is y-down, so this is the bottom.
    static let arcStart = Angle.degrees(90)
    /// Twelve o'clock.
    static let arcEnd = Angle.degrees(270)
    /// Centred on three o'clock and symmetric about it, which is what makes the ring read
    /// as thinning out rather than as a gap in one place.
    static let dotAngles: [Angle] = stride(from: -72.0, through: 72.0, by: 18.0)
        .map(Angle.degrees)
    /// Straight up, and longer than a clock's hour hand usually is — measured, not chosen.
    static let hourHandTip = CGPoint(x: 12, y: 5)
    /// Nine o'clock.
    static let minuteHandTip = CGPoint(x: 6.5, y: 12)
}

#Preview {
    VStack(spacing: 20) {
        EphemeralClockGlyph(height: 16)
        EphemeralClockGlyph(height: 44)
        HStack(spacing: 8) {
            Image(systemName: "headphones.circle.fill")
            Text("magnus-health huddle")
            Spacer()
            EphemeralClockGlyph(height: 16)
        }
        .padding(.horizontal)
    }
    .foregroundStyle(.secondary)
    .padding()
    .preferredColorScheme(.dark)
}
