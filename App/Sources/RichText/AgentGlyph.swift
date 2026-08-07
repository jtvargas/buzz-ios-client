import SwiftUI

/// The **lucide `bot`** glyph, the mark both official Buzz clients put in place of the
/// `@` on a mention of an agent.
///
/// # Why it is a `Path` and not an asset
///
/// It is drawn by ``RichTextEntityRenderer``, inside a `TextRenderer`'s
/// `GraphicsContext`, in the space the mention's own `@` occupies. That context takes
/// shapes, not views — so an `Image` in the `AttributedString` was never an option
/// here, and a bitmap asset would have to be exported at every Dynamic Type size the
/// app supports. Stroking a path costs neither.
///
/// # Where the shape comes from
///
/// Lifted verbatim from the desktop client, which draws it as a CSS mask with the SVG
/// inline — `desktop/src/shared/styles/globals/markdown.css`, the
/// `.agent-mention-highlight::before` rule. The Flutter client draws the same icon as
/// `LucideIcons.bot`. Taking the path data rather than eyeballing the picture is the
/// only way the three clients are drawing the *same* mark rather than three similar
/// ones.
///
/// The source, unchanged:
///
/// ```svg
/// <svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2"
///      stroke-linecap="round" stroke-linejoin="round">
///   <path d="M12 8V4H8"/>
///   <rect width="16" height="12" x="4" y="8" rx="2"/>
///   <path d="M2 14h2"/>
///   <path d="M20 14h2"/>
///   <path d="M15 13v2"/>
///   <path d="M9 13v2"/>
/// </svg>
/// ```
///
/// It is a *stroked* icon: the path carries no fill, and the 2-unit stroke is as much
/// of the drawing as the geometry is. Filling it would produce a solid blob, so
/// ``strokeStyle(side:)`` is not optional decoration — it is half the glyph.
enum AgentGlyph {
    /// The side of lucide's own coordinate box. Everything below is expressed in it and
    /// scaled once, so the numbers can be compared against the SVG by eye.
    private static let viewBox: CGFloat = 24
    /// lucide's `stroke-width`, in those same units.
    private static let strokeWidth: CGFloat = 2

    /// The glyph's outline, scaled to fill a `side`-point square whose origin is
    /// `origin`.
    ///
    /// The square is the *view box*, not the ink: lucide insets the drawing from it
    /// (the antennae reach x=2 and x=22 of 24, the body y=4 to y=20), and that inset is
    /// the icon's own optical padding. Fitting the ink instead would draw this mark
    /// noticeably larger than the same icon on desktop and in Flutter.
    static func path(in rect: CGRect) -> Path {
        let scale = rect.width / viewBox
        /// A point in lucide's own 24-unit space, placed in `rect`. Taking the SVG's
        /// numbers unchanged is what makes the calls below checkable against the source.
        func point(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + unitX * scale, y: rect.minY + unitY * scale)
        }

        var path = Path()

        // <path d="M12 8V4H8"/> — the head's stalk and its cap.
        path.move(to: point(12, 8))
        path.addLine(to: point(12, 4))
        path.addLine(to: point(8, 4))

        // <rect width="16" height="12" x="4" y="8" rx="2"/> — the face.
        path.addRoundedRect(
            in: CGRect(
                origin: point(4, 8),
                size: CGSize(width: 16 * scale, height: 12 * scale)
            ),
            cornerSize: CGSize(width: 2 * scale, height: 2 * scale),
            style: .circular
        )

        // <path d="M2 14h2"/> and <path d="M20 14h2"/> — the ears.
        path.move(to: point(2, 14))
        path.addLine(to: point(4, 14))
        path.move(to: point(20, 14))
        path.addLine(to: point(22, 14))

        // <path d="M15 13v2"/> and <path d="M9 13v2"/> — the eyes.
        path.move(to: point(15, 13))
        path.addLine(to: point(15, 15))
        path.move(to: point(9, 13))
        path.addLine(to: point(9, 15))

        return path
    }

    /// lucide's stroke, scaled to a glyph of `side` points: 2 units of 24, round caps
    /// and round joins.
    ///
    /// The eyes are two-unit segments with round caps, so at small sizes they read as
    /// dots — which is what makes the icon legible at text size at all. A butt cap
    /// would lose them.
    static func strokeStyle(side: CGFloat) -> StrokeStyle {
        StrokeStyle(
            lineWidth: strokeWidth * (side / viewBox),
            lineCap: .round,
            lineJoin: .round
        )
    }

    // MARK: - Placing it on a line of text

    /// How much of the font's em box the glyph occupies.
    ///
    /// Desktop sets `--agent-icon-size: 0.95em` and Flutter asks for `fontSize * 0.95`;
    /// this is that number, expressed against the em rather than against the run's
    /// typographic height, because the two are not the same and only the em is the
    /// thing both other clients scale by.
    static let emScale: CGFloat = 0.95

    /// Clear space between the bot and the agent name inside the mention highlight.
    ///
    /// This is layout advance, not a character inserted into the message, so copying the
    /// rendered mention still produces `@Name` for another client to resolve.
    static let nameGap: CGFloat = 4

    /// Where the glyph's square sits relative to one laid-out run of text.
    ///
    /// - Parameters:
    ///   - rect: the run's typographic bounds.
    ///   - ascent: the run's ascent, i.e. how far `rect.minY` is above the baseline.
    ///   - descent: the run's descent.
    ///
    /// Centred on the **optical middle of lowercase text** rather than on the run's own
    /// midpoint. A run's typographic box is ascent + descent, which is taller than an em
    /// and hangs well below the letters; centring in it would sit the bot visibly low
    /// against the name beside it. The centre used here is a third of the em above the
    /// baseline, which lands on the middle of an `x` for the app's face.
    ///
    /// Horizontally centred in the run — the run being the `@` this replaces, whose
    /// advance is close enough to an em that no space has to be opened for the glyph.
    /// That is the whole reason the `@` is kept and hidden rather than removed: it is
    /// already exactly the right amount of layout.
    static func frame(in rect: CGRect, ascent: CGFloat, descent: CGFloat) -> CGRect {
        // The em, recovered from the run. A font's ascent + descent is its line's
        // extent, not its em square; for the app's face that is ~1.21em, and dividing
        // it back out is what keeps `emScale` meaning the same thing it means in the
        // other two clients.
        let em = (ascent + descent) / 1.21
        let side = em * emScale
        let baseline = rect.minY + ascent
        let centreY = baseline - em / 3
        return CGRect(
            x: rect.midX - side / 2,
            y: centreY - side / 2,
            width: side,
            height: side
        )
    }
}
