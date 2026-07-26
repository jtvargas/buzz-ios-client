import CoreGraphics
import Foundation

extension SVGAvatarDocument {
    /// Collects the supported elements out of one `XMLParser` pass.
    ///
    /// A class because `XMLParserDelegate` is a class protocol. It is created, used, and
    /// dropped inside ``SVGAvatarDocument/init(data:)``, so it never crosses an isolation
    /// boundary and needs no `Sendable` conformance — the parse as a whole is a pure
    /// synchronous function of its input.
    final class Collector: NSObject, XMLParserDelegate {
        /// The coordinate system the drawing elements are expressed in: the first
        /// *drawable* `<svg>`'s box. A later `<svg>` does not replace it, and one inside a
        /// `<defs>` (or any other non-rendering element) does not establish it — a
        /// definition describes something to be referenced, so letting it decide the
        /// viewport would let a document draw in one coordinate system and measure in
        /// another.
        private(set) var viewBox: CGRect?
        private(set) var elements: [Element] = []

        /// Nesting depth inside an element whose children are definitions rather than
        /// drawing — `<defs>`, `<clipPath>`, and friends, plus the metadata elements whose
        /// character data would otherwise be mistaken for avatar text.
        private var suppressionDepth = 0
        private var pendingRun: SVGTextRun?
        private var pending = PendingText()

        private static let nonRendering: Set<String> = [
            "defs", "clippath", "mask", "symbol", "marker", "pattern",
            "metadata", "title", "desc", "style", "script",
        ]

        // MARK: XMLParserDelegate

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes attributeDict: [String: String]
        ) {
            let name = Self.localName(elementName)
            if Self.nonRendering.contains(name) {
                suppressionDepth += 1
                return
            }

            let attributes = Self.lowercasingKeys(attributeDict)
            if name == "svg" {
                // Suppression is checked here and not only below, because the root element
                // is the one that decides the coordinate system: an `<svg>` nested inside
                // `<defs>` is a definition like any other, and a definition that could set
                // the viewport would move every drawn element without being drawn itself.
                if suppressionDepth == 0, viewBox == nil {
                    viewBox = SVGAvatarDocument.viewBox(from: attributes)
                }
                return
            }
            // Elements before a usable root `viewBox` have no coordinate system to be
            // expressed in, so they are dropped rather than guessed at.
            guard suppressionDepth == 0, let viewBox else { return }

            switch name {
            case "rect": append(Self.rectangle(attributes, in: viewBox))
            case "circle": append(Self.circle(attributes, in: viewBox))
            case "ellipse": append(Self.ellipse(attributes, in: viewBox))
            case "text":
                pendingRun = Self.textRun(attributes, in: viewBox)
                pending.reset()
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Bounded so a payload that pads a `<text>` element with a hundred kilobytes
            // of characters does not build the string only for it to be truncated. The
            // slack over the draw cap leaves room for surrounding whitespace.
            guard suppressionDepth == 0,
                  pendingRun != nil,
                  pending.byteCount < SVGAvatarDocument.maximumTextByteCount
            else { return }
            pending.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let name = Self.localName(elementName)
            if Self.nonRendering.contains(name) {
                suppressionDepth = max(0, suppressionDepth - 1)
                return
            }
            guard name == "text", var run = pendingRun else { return }
            pendingRun = nil

            let trimmed = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
            pending.reset()
            guard !trimmed.isEmpty else { return }
            // Truncated by *scalar*, not by `Character`: a base character followed by a
            // hundred thousand combining marks is one grapheme cluster, so `prefix` over
            // the characters view of it truncates nothing and hands Core Text the whole
            // run to lay out. The scalar count is what bounds the shaping work.
            run.text = String(String.UnicodeScalarView(
                trimmed.unicodeScalars.prefix(SVGAvatarDocument.maximumTextLength)
            ))
            append(.text(run))
        }

        private func append(_ element: Element?) {
            guard let element, elements.count < SVGAvatarDocument.maximumElementCount else {
                return
            }
            elements.append(element)
        }
    }
}

// MARK: - Character data

extension SVGAvatarDocument.Collector {
    /// The character data accumulated for the `<text>` element being parsed, with its
    /// UTF-8 length carried alongside.
    ///
    /// The length is carried rather than recomputed because the cap is checked once per
    /// `foundCharacters` callback and `XMLParser` delivers a long run of character data in
    /// chunks of a few hundred bytes. Asking the accumulated string for its `count` there
    /// was the whole cost: `String.count` walks the text breaking graphemes, so the guard
    /// meant to bound the payload was itself quadratic in it — and, because grapheme
    /// clusters are what it counted, a payload made of combining marks stayed one
    /// `Character` long and never reached the bound at all.
    struct PendingText {
        private(set) var text = ""
        /// The UTF-8 length of ``text``. Maintained incrementally, so reading it is O(1)
        /// no matter what storage form the accumulated string is in.
        private(set) var byteCount = 0

        mutating func append(_ string: String) {
            text += string
            byteCount += string.utf8.count
        }

        mutating func reset() {
            text = ""
            byteCount = 0
        }
    }
}

// MARK: - Element decoding

extension SVGAvatarDocument.Collector {
    /// Strips any namespace prefix and lowercases, so `<svg:rect>` and `<RECT>` both
    /// match. Namespace processing is left off on the parser, so `elementName` is the
    /// qualified name.
    private static func localName(_ elementName: String) -> String {
        let name = elementName.split(separator: ":").last ?? Substring(elementName)
        return name.lowercased()
    }

    /// Lowercases attribute names for lookup. XML attribute names are case-sensitive, so
    /// this is a leniency, not a correction — none of the supported attributes differ from
    /// one another only by case, so it costs nothing and it accepts the `viewbox` spelling
    /// that hand-written SVG sometimes uses.
    private static func lowercasingKeys(_ attributes: [String: String]) -> [String: String] {
        Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// The `fill` an element paints with: its own attribute, or SVG's initial black when
    /// it names none. `nil` means "do not draw this element" — either `fill="none"` or a
    /// paint outside the supported grammar.
    private static func fill(_ attributes: [String: String]) -> SVGColor? {
        guard let raw = attributes["fill"] else { return .black }
        return SVGColor(paint: raw)
    }

    private static func rectangle(
        _ attributes: [String: String],
        in viewBox: CGRect
    ) -> SVGAvatarDocument.Element? {
        guard let width = SVGAvatarDocument.length(attributes["width"], percentOf: viewBox.width),
              let height = SVGAvatarDocument.length(attributes["height"], percentOf: viewBox.height),
              width > 0, height > 0,
              let fill = fill(attributes)
        else { return nil }

        let originX = SVGAvatarDocument.length(attributes["x"], percentOf: viewBox.width) ?? 0
        let originY = SVGAvatarDocument.length(attributes["y"], percentOf: viewBox.height) ?? 0
        // In SVG a missing `rx` takes `ry`'s value and vice versa. That rule is what makes
        // the emoji template's lone `rx="256"` on a 512-square a full circle rather than a
        // capsule, so it is not optional.
        let radiusX = SVGAvatarDocument.length(attributes["rx"], percentOf: viewBox.width)
        let radiusY = SVGAvatarDocument.length(attributes["ry"], percentOf: viewBox.height)
        let corner = CGSize(
            width: max(0, radiusX ?? radiusY ?? 0),
            height: max(0, radiusY ?? radiusX ?? 0)
        )
        return .rectangle(
            frame: CGRect(x: originX, y: originY, width: width, height: height),
            corner: corner,
            fill: fill
        )
    }

    private static func circle(
        _ attributes: [String: String],
        in viewBox: CGRect
    ) -> SVGAvatarDocument.Element? {
        // SVG resolves a percentage `r` against the normalised diagonal — `√((w²+h²)/2)`,
        // which is `√(w²+h²)/√2` — rather than against either edge.
        let normalizedDiagonal =
            ((viewBox.width * viewBox.width + viewBox.height * viewBox.height) / 2).squareRoot()
        guard let radius = SVGAvatarDocument.length(attributes["r"], percentOf: normalizedDiagonal),
              radius > 0,
              let fill = fill(attributes)
        else { return nil }
        let centerX = SVGAvatarDocument.length(attributes["cx"], percentOf: viewBox.width) ?? 0
        let centerY = SVGAvatarDocument.length(attributes["cy"], percentOf: viewBox.height) ?? 0
        return .ellipse(
            frame: CGRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            ),
            fill: fill
        )
    }

    private static func ellipse(
        _ attributes: [String: String],
        in viewBox: CGRect
    ) -> SVGAvatarDocument.Element? {
        guard let radiusX = SVGAvatarDocument.length(attributes["rx"], percentOf: viewBox.width),
              let radiusY = SVGAvatarDocument.length(attributes["ry"], percentOf: viewBox.height),
              radiusX > 0, radiusY > 0,
              let fill = fill(attributes)
        else { return nil }
        let centerX = SVGAvatarDocument.length(attributes["cx"], percentOf: viewBox.width) ?? 0
        let centerY = SVGAvatarDocument.length(attributes["cy"], percentOf: viewBox.height) ?? 0
        return .ellipse(
            frame: CGRect(
                x: centerX - radiusX,
                y: centerY - radiusY,
                width: radiusX * 2,
                height: radiusY * 2
            ),
            fill: fill
        )
    }

    /// The text run an element's attributes describe, with its content still to come from
    /// `foundCharacters`.
    private static func textRun(_ attributes: [String: String], in viewBox: CGRect) -> SVGTextRun? {
        guard let fill = fill(attributes) else { return nil }
        // A missing `font-size` is CSS's initial 16 user units. A *percentage* would
        // resolve against an inherited size this parser does not model, so it falls back
        // to that same default rather than silently resolving against the viewport.
        let declared = attributes["font-size"].flatMap { raw -> CGFloat? in
            raw.contains("%") ? nil : SVGAvatarDocument.length(raw, percentOf: 0)
        }
        let ceiling = SVGAvatarDocument.maximumFontSizeRatio * max(viewBox.width, viewBox.height)
        let fontSize = min(max(declared ?? 16, 0), ceiling)
        guard fontSize > 0 else { return nil }

        return SVGTextRun(
            text: "",
            origin: CGPoint(
                x: SVGAvatarDocument.length(attributes["x"], percentOf: viewBox.width) ?? 0,
                y: SVGAvatarDocument.length(attributes["y"], percentOf: viewBox.height) ?? 0
            ),
            fontSize: fontSize,
            anchor: .parse(attributes["text-anchor"]),
            baseline: .parse(attributes["dominant-baseline"]),
            fill: fill
        )
    }
}
