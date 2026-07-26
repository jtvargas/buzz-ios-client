import Foundation

/// One stretch of an inline that the renderer treats as a unit: either plain text, or
/// a single interactive range carrying its target's URL.
struct RichTextSegment: Equatable {
    let range: Range<AttributedString.Index>
    /// The interactive target's URL, or `nil` for ordinary text. Its
    /// `absoluteString` is the pill's identity — what the flash compares against.
    let link: URL?
}

/// Splits a styled inline into the segments a `Text` is built from.
///
/// # Why this exists at all
///
/// A pill cannot be drawn from an `AttributedString` attribute. Measured in a
/// harness: a custom attribute carried inside an `AttributedString` is *invisible* to
/// `Text.Layout`, so a `TextRenderer` cannot see it — only `Text.customAttribute(_:)`
/// on a concatenated `Text` reaches the layout. And `AttributedString`'s own
/// `backgroundColor` is a bare rectangle with no corner radius and no padding.
///
/// So an inline is rendered as concatenated `Text` pieces, one per segment, with the
/// interactive ones marked. Segmentation is the part with the rules, so it is data
/// rather than view code — and testable without a view host.
///
/// Adjacent runs sharing a link are one segment: `@**Ada** Lovelace` is three runs
/// (plain, bold, plain) and must still draw a single pill rather than three abutting
/// ones with seams between them.
enum RichTextSegments {
    static func segments(of attributed: AttributedString) -> [RichTextSegment] {
        var segments: [RichTextSegment] = []
        for run in attributed.runs {
            if let last = segments.last,
               last.link == run.link,
               last.range.upperBound == run.range.lowerBound {
                segments[segments.count - 1] = RichTextSegment(
                    range: last.range.lowerBound ..< run.range.upperBound,
                    link: last.link
                )
            } else {
                segments.append(RichTextSegment(range: run.range, link: run.link))
            }
        }
        return segments
    }
}
