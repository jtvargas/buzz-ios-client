import CoreGraphics
import Foundation

/// The slice of SVG an avatar tile needs, parsed into flat drawing instructions.
///
/// # Why parse a subset instead of rendering SVG properly
///
/// ImageIO ships no SVG decoder, so `data:image/svg+xml` avatars — including the
/// workspace owner's — fall through the normal decode path to `nil` and every one of them
/// shows as initials. The dependency-free options, and why this one:
///
/// - **`WKWebView` + `takeSnapshot`** renders arbitrary SVG correctly and is the only
///   general answer. It also brings a web content process per snapshot, a main-actor hop
///   out of a background loader, a bounded-timeout race so a payload that never finishes
///   laying out cannot pin that loader, a navigation policy so a hostile
///   `<image href="https://…">` cannot phone home, and an attached-to-a-window
///   requirement that makes off-screen snapshots unreliable and unit tests flaky. That is
///   a lot of load-bearing machinery for artwork whose failure mode is an already-good
///   monogram.
/// - **`NSAttributedString`'s HTML importer** is WebKit with none of those controls, is
///   main-actor only, and offers no way to ask for a particular raster size.
/// - **Apple's private `CoreSVG`** (`CGSVGDocumentCreateFromData`) is what UIKit itself
///   uses for asset-catalog SVGs, and is private API.
///
/// So: parse the subset, draw it with Core Graphics and Core Text. That is sound here
/// because the SVG corpus is a single generator template — Buzz's `emojiAvatarDataUrl()`
/// emits exactly one `<rect>` plus one `<text>` — and because Buzz's *desktop* client
/// already reads these avatars back the same way, extracting `{colour, emoji}` rather
/// than rendering the document (`parseEmojiAvatarDataUrl`). Matching that keeps both
/// clients' idea of "an emoji avatar" identical. Anything outside the subset parses to
/// `nil`, which is the monogram: the correct fallback, reached without a hang.
///
/// Everything here is pure and synchronous. There is no executor to block, no timeout to
/// get wrong, and no code path that can run longer than the caps below allow.
struct SVGAvatarDocument: Equatable, Sendable {
    /// The user-space rectangle the contents are expressed in — `viewBox`, or
    /// `width`/`height` when there is no `viewBox`.
    var viewBox: CGRect
    /// The drawing instructions, in document order.
    var elements: [Element]

    /// One supported drawing instruction.
    enum Element: Equatable, Sendable {
        /// A filled rectangle, with elliptical corners when `rx`/`ry` are present.
        case rectangle(frame: CGRect, corner: CGSize, fill: SVGColor)
        /// A filled ellipse — both `<circle>` and `<ellipse>` land here.
        case ellipse(frame: CGRect, fill: SVGColor)
        /// A single run of text: the glyph an emoji avatar is built around.
        case text(SVGTextRun)
    }

    /// The largest document this will attempt, in bytes. Three orders of magnitude above
    /// the 371-byte template these actually are.
    static let maximumByteCount = 256 * 1024
    /// The most instructions kept from one document. Bounds render time no matter what
    /// the payload claims to contain.
    static let maximumElementCount = 64
    /// The most characters drawn from one `<text>` run. An avatar glyph is one grapheme;
    /// the rest is truncated rather than rejected, so a padded payload still renders.
    static let maximumTextLength = 32
    /// The largest `font-size`, as a multiple of the viewBox's longest edge. Clamped
    /// rather than rejected so an over-eager template still draws something.
    static let maximumFontSizeRatio: CGFloat = 4
}

// MARK: - Parsing

extension SVGAvatarDocument {
    /// Parses `data` as an SVG document, keeping only the supported elements.
    ///
    /// Returns `nil` for anything that is not well-formed XML, is over
    /// ``maximumByteCount``, has no usable `viewBox`, or contains nothing this subset can
    /// draw — so a payload that "never renders" resolves rather than hanging.
    init?(data: Data) {
        guard !data.isEmpty,
              data.count <= Self.maximumByteCount,
              let text = String(data: data, encoding: .utf8),
              Self.hasNoDocumentTypeDeclaration(text)
        else { return nil }

        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = collector
        // `XMLParser.delegate` is an unowned reference, so ARC is free to release
        // `collector` the instant after the assignment — its last use — and hand the
        // parser a dangling delegate. Extending the lifetime across `parse()` is what
        // makes this safe.
        let parsed = withExtendedLifetime(collector) { parser.parse() }

        guard parsed, let viewBox = collector.viewBox, !collector.elements.isEmpty else {
            return nil
        }
        self.viewBox = viewBox
        self.elements = collector.elements
    }

    /// Whether the document declares no DTD.
    ///
    /// Internal entity expansion ("billion laughs") is the one way a small, well-formed
    /// XML document can cost unbounded time and memory, and libxml2's own limits are not
    /// something to bet an attacker-supplied payload on. An avatar has no legitimate use
    /// for a doctype, so refusing one outright is both the cheapest and the strongest
    /// guard available. External entities are separately disabled on the parser.
    private static func hasNoDocumentTypeDeclaration(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return !lowered.contains("<!doctype") && !lowered.contains("<!entity")
    }
}

// MARK: - Value grammar

extension SVGAvatarDocument {
    /// A coordinate or length in SVG's grammar: a plain number in user units, an explicit
    /// `px`, or a percentage of `reference`.
    ///
    /// Deliberately narrow. Physical units (`mm`, `pt`, `in`) and font-relative units
    /// (`em`, `ex`) are rejected rather than approximated, because an avatar tile that is
    /// silently the wrong size is worse than one that falls back to a monogram.
    static func length(_ text: String?, percentOf reference: CGFloat) -> CGFloat? {
        guard var token = text?.trimmingCharacters(in: .whitespaces), !token.isEmpty else {
            return nil
        }
        var isPercentage = false
        if token.hasSuffix("%") {
            isPercentage = true
            token.removeLast()
        } else if token.lowercased().hasSuffix("px") {
            token.removeLast(2)
        }
        guard let value = Double(token.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            return nil
        }
        let length = isPercentage ? CGFloat(value) / 100 * reference : CGFloat(value)
        return length.isFinite ? length : nil
    }

    /// The viewBox a root `<svg>` establishes: its `viewBox` attribute, or its
    /// `width`/`height` as an origin-anchored box, or `nil` when neither is usable.
    static func viewBox(from attributes: [String: String]) -> CGRect? {
        if let raw = attributes["viewbox"] {
            let numbers = raw
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .compactMap { Double($0) }
            if numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 {
                return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
        }
        // Percentage width/height on the root have nothing to resolve against, so a
        // reference of 0 makes them fail the `> 0` check below rather than resolve to 0.
        guard let width = length(attributes["width"], percentOf: 0),
              let height = length(attributes["height"], percentOf: 0),
              width > 0, height > 0
        else { return nil }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}
