import SwiftUI

/// The marker an interactive `Text` segment carries so the renderer can find it.
///
/// A `TextAttribute` and not an `AttributedStringKey`: measured in a harness, a
/// custom `AttributedString` attribute never appears in `Text.Layout`, so a renderer
/// cannot see it. `Text.customAttribute(_:)` does.
struct RichTextEntityMarker: TextAttribute {
    /// The target's URL string — the same value the flash compares against, so the
    /// renderer never has to know what kind of entity it is drawing.
    let key: String
}

/// Builds the `Text` one inline is drawn as.
enum RichTextInline {
    /// One inline as concatenated `Text`, each interactive range marked so
    /// ``RichTextEntityRenderer`` can draw its pill and carrying the `link` that
    /// makes it pressable.
    ///
    /// See ``RichTextSegments`` for why an inline is no longer a single
    /// `Text(attributedString)`.
    static func text(_ attributed: AttributedString, base: Font) -> Text {
        let styled = RichTextStyle.styled(attributed, base: base, interactive: true)
        return RichTextSegments.segments(of: styled).reduce(Text("")) { text, segment in
            let piece = Text(AttributedString(styled[segment.range]))
            guard let link = segment.link else { return text + piece }
            return text + piece.customAttribute(RichTextEntityMarker(key: link.absoluteString))
        }
    }
}

/// Draws the rounded tint behind every interactive range of a message, and nothing
/// else about it.
///
/// # Why a renderer rather than an attribute
///
/// `AttributedString.backgroundColor` fills a bare rectangle: no corner radius, no
/// padding, and it stops exactly at the glyphs. A `TextRenderer` gets the laid-out
/// run rects, so the pill can be grown past the text and rounded — and, because it
/// works per *line fragment*, a link that wraps draws one rounded shape on each line
/// instead of one box spanning both.
///
/// Everything else the text needs is untouched: the runs are drawn back exactly as
/// they were laid out, so Dynamic Type, wrapping, emphasis, and VoiceOver are still
/// the system's.
struct RichTextEntityRenderer: TextRenderer, Equatable {
    /// The pill currently flashing — the target's URL string, or `nil`.
    var flashing: String?
    /// Whether to use the dark-mode alphas.
    var dark: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for (key, rect) in Self.pills(in: line) {
                context.fill(
                    Path(
                        roundedRect: rect.insetBy(
                            dx: -RichTextStyle.pillPadding.width,
                            dy: -RichTextStyle.pillPadding.height
                        ),
                        cornerRadius: RichTextStyle.pillCornerRadius,
                        style: .continuous
                    ),
                    with: .color(RichTextStyle.pillFill(dark: dark, pressed: key == flashing))
                )
            }
        }
        // A custom renderer owns the whole draw: nothing is drawn unless it is drawn
        // here, so the glyphs go down after the fills, in layout order.
        for line in layout {
            for run in line {
                context.draw(run)
            }
        }
    }

    /// One rect per interactive range *per line*, merged across adjacent runs.
    ///
    /// A pill has to be merged twice over, for two different reasons:
    ///
    /// - emphasis splits a range into several layout runs (`@**Ada** Lovelace` is
    ///   three), and filling each separately overlaps their padding — which showed as
    ///   brighter seams around the bold word, because the two fills compound;
    /// - a range that wraps produces runs on more than one line, and those must stay
    ///   separate, or one rounded shape would be stretched across the gap between
    ///   them.
    ///
    /// So: merge along a line, break at the end of it.
    static func pills(in line: Text.Layout.Line) -> [(key: String, rect: CGRect)] {
        merged(line.map { ($0[RichTextEntityMarker.self]?.key, $0.typographicBounds.rect) })
    }

    /// The merge itself, over plain values — `Text.Layout.Line` cannot be built in a
    /// test, and this is the part with a rule in it.
    ///
    /// Only *adjacent* runs merge. Two references to the same person on one line are
    /// two pills, and unioning them would paint one shape straight through the words
    /// between them.
    static func merged(_ runs: [(key: String?, rect: CGRect)]) -> [(key: String, rect: CGRect)] {
        var pills: [(key: String, rect: CGRect)] = []
        var isContiguous = false
        for run in runs {
            guard let key = run.key else {
                isContiguous = false
                continue
            }
            if isContiguous, let last = pills.last, last.key == key {
                pills[pills.count - 1] = (key, last.rect.union(run.rect))
            } else {
                pills.append((key, run.rect))
            }
            isContiguous = true
        }
        return pills
    }
}
