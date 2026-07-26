import CoreGraphics
import CoreText
import UIKit

/// Rasterises a parsed ``SVGAvatarDocument`` at an exact pixel size, using Core Graphics
/// for shapes and Core Text for glyphs.
///
/// Pure and synchronous, and safe off the main thread: `UIGraphicsImageRenderer` carries
/// no main-actor annotation and is documented as usable from any thread, `UIFont` is
/// `Sendable`, and Core Text is thread-safe. Nothing here suspends, so a payload can cost
/// at most the bounded work ``SVGAvatarDocument``'s caps allow — it can never hang the
/// loader that called it.
enum SVGAvatarRenderer {
    /// The image an SVG payload renders to, no larger than `pixelSize` on its longest
    /// edge, or `nil` if it is not a document this subset understands.
    static func image(svg data: Data, pixelSize: CGFloat) -> UIImage? {
        guard let document = SVGAvatarDocument(data: data) else { return nil }
        return image(document, pixelSize: pixelSize)
    }

    /// Renders a parsed document. Split out from ``image(svg:pixelSize:)`` so the parse
    /// and the raster can be exercised separately.
    static func image(_ document: SVGAvatarDocument, pixelSize: CGFloat) -> UIImage? {
        guard let geometry = Geometry(viewBox: document.viewBox, pixelSize: pixelSize) else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        // `pixelSize` is already in pixels — the caller multiplied points by the display
        // scale — so the renderer must not scale again.
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: geometry.size, format: format)
        return renderer.image { context in
            draw(document, geometry: geometry, in: context.cgContext)
        }
    }

    /// The mapping from the document's user space onto the output bitmap.
    struct Geometry: Equatable {
        /// The bitmap's size. Points equal pixels here because the format's scale is 1.
        let size: CGSize
        /// User units to pixels.
        let scale: CGFloat
        /// The viewBox origin, subtracted so a non-zero origin lands at the top left.
        let origin: CGPoint

        /// Fits `viewBox` into a box whose longest edge is `pixelSize`, preserving aspect
        /// ratio — the same contract as ``AvatarLoader/downsample(_:maxPixelSize:)``, so a
        /// vector and a raster avatar of the same shape come out the same size.
        ///
        /// `nil` for a degenerate or non-finite viewBox, which is also the guard against a
        /// payload asking for an absurd allocation.
        init?(viewBox: CGRect, pixelSize: CGFloat) {
            guard viewBox.width.isFinite, viewBox.height.isFinite,
                  viewBox.width > 0, viewBox.height > 0,
                  viewBox.origin.x.isFinite, viewBox.origin.y.isFinite,
                  pixelSize.isFinite, pixelSize >= 1
            else { return nil }

            let scale = pixelSize / max(viewBox.width, viewBox.height)
            let width = (viewBox.width * scale).rounded()
            let height = (viewBox.height * scale).rounded()
            // The derived values are checked as well as the declared ones, because a box
            // can be finite and positive on every edge and still imply a scale that is
            // not: `viewBox="0 0 1e-308 1e-308"` passes every test above and divides into
            // an infinite scale, and an infinite scale multiplies back into an infinite
            // size. `max(1, …)` cannot be relied on to catch that — Swift's `max` returns
            // its first argument for a NaN second one, quietly turning a NaN edge into a
            // 1-pixel one — so the products are inspected before they are clamped, and
            // `UIGraphicsImageRenderer` is never handed a non-finite size.
            guard scale.isFinite, scale > 0, width.isFinite, height.isFinite else {
                return nil
            }

            self.scale = scale
            self.origin = viewBox.origin
            self.size = CGSize(width: max(1, width), height: max(1, height))
        }
    }
}

// MARK: - Drawing

extension SVGAvatarRenderer {
    private static func draw(_ document: SVGAvatarDocument, geometry: Geometry, in context: CGContext) {
        // `UIGraphicsImageRenderer` hands over a context whose y axis already grows
        // downward, which is SVG's own orientation, so the only transform shapes need is
        // the viewBox one. Applied scale-then-translate so that a user point `p` maps to
        // `(p - viewBox.origin) * scale`.
        context.scaleBy(x: geometry.scale, y: geometry.scale)
        context.translateBy(x: -geometry.origin.x, y: -geometry.origin.y)

        for element in document.elements {
            switch element {
            case let .rectangle(frame, corner, fill):
                draw(rectangle: frame, corner: corner, fill: fill, in: context)
            case let .ellipse(frame, fill):
                context.setFillColor(fill.cgColor)
                context.fillEllipse(in: frame)
            case let .text(run):
                draw(run, in: context)
            }
        }
    }

    private static func draw(
        rectangle: CGRect,
        corner: CGSize,
        fill: SVGColor,
        in context: CGContext
    ) {
        context.setFillColor(fill.cgColor)
        guard corner.width > 0 || corner.height > 0 else {
            context.fill(rectangle)
            return
        }
        // `CGPath(roundedRect:)` is undefined for corner radii over half the edge, and
        // SVG's own clamp is exactly that half — which is how `rx="256"` on a 512-square
        // becomes a circle rather than an overflow.
        let path = CGPath(
            roundedRect: rectangle,
            cornerWidth: min(corner.width, rectangle.width / 2),
            cornerHeight: min(corner.height, rectangle.height / 2),
            transform: nil
        )
        context.addPath(path)
        context.fillPath()
    }

    private static func draw(_ run: SVGTextRun, in context: CGContext) {
        let font = UIFont.systemFont(ofSize: run.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            // Take the colour from the context rather than a `CTForegroundColor`
            // attribute, so one `setFillColor` covers shapes and glyphs alike. Colour
            // emoji ignore it, which is correct — their glyphs carry their own bitmaps.
            .init(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        // Core Text substitutes fonts across the system font's cascade list, which is what
        // resolves an emoji scalar to Apple Color Emoji without naming that font here.
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: run.text, attributes: attributes)
        )

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        context.saveGState()
        context.setFillColor(run.fill.cgColor)
        // Core Text advances glyphs up the y axis; this context's y axis points down.
        // Flipping the *text* matrix rather than the CTM keeps `textPosition` in the same
        // user-space coordinates every shape above uses, with y on the baseline.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: anchoredX(run, width: width),
            y: baselineY(run, font: font, ascent: ascent, descent: descent)
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Where the run starts, given which end of its advance width `text-anchor` pins to
    /// `origin.x`. The advance width — not the ink bounds — is what SVG specifies.
    static func anchoredX(_ run: SVGTextRun, width: CGFloat) -> CGFloat {
        switch run.anchor {
        case .start: run.origin.x
        case .middle: run.origin.x - width / 2
        case .end: run.origin.x - width
        }
    }

    /// Where the baseline sits, given which alignment baseline `dominant-baseline` pins to
    /// `origin.y`.
    ///
    /// The shifts are the CSS definitions of each alignment baseline's offset above the
    /// alphabetic one, and they matter: the emoji template writes `y="56%"` with
    /// `dominant-baseline="middle"`, and it is the half-x-height shift that turns those
    /// into a glyph optically centred in the tile. Centring the glyph box on `y` instead —
    /// the obvious shortcut — lands it about 6% of the tile too low.
    ///
    /// `ascent`/`descent` come from the laid-out line rather than from `font`, so they
    /// describe the emoji font Core Text actually substituted.
    static func baselineY(
        _ run: SVGTextRun,
        font: UIFont,
        ascent: CGFloat,
        descent: CGFloat
    ) -> CGFloat {
        switch run.baseline {
        case .alphabetic: run.origin.y
        case .middle: run.origin.y + font.xHeight / 2
        case .central: run.origin.y + (ascent - descent) / 2
        case .hanging: run.origin.y + ascent
        case .textAfterEdge: run.origin.y - descent
        }
    }
}
