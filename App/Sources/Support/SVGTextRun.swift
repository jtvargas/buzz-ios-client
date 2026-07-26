import CoreGraphics
import Foundation

/// A single `<text>` element reduced to what it takes to place one run of glyphs: the
/// string, the anchor point in user space, the type size, and the two alignment
/// attributes an emoji avatar relies on.
///
/// The font *family* is deliberately not carried. Emoji avatars name no family, and the
/// glyph is a colour emoji that only ever resolves through the system font's cascade
/// anyway; honouring `font-family` would mean matching arbitrary names against installed
/// fonts, which is a much larger promise than an avatar tile needs.
struct SVGTextRun: Equatable, Sendable {
    /// The text content, already XML-unescaped by the parser and length-capped.
    var text: String
    /// The `x`/`y` anchor in user space. Which edge of the run this is depends on
    /// ``anchor``, and which line of the glyphs sits on it depends on ``baseline``.
    var origin: CGPoint
    /// `font-size`, in user units.
    var fontSize: CGFloat
    var anchor: Anchor
    var baseline: Baseline
    var fill: SVGColor

    /// SVG's `text-anchor`: which end of the run's advance width lands on `origin.x`.
    enum Anchor: Sendable {
        case start
        case middle
        case end

        /// Parses `text-anchor`, defaulting to `start` — SVG's initial value, and the
        /// right answer for an unrecognised keyword too.
        static func parse(_ text: String?) -> Anchor {
            switch text?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "middle": .middle
            case "end": .end
            default: .start
            }
        }
    }

    /// SVG's `dominant-baseline`, narrowed to the alignments that change where an avatar
    /// glyph sits.
    ///
    /// `hanging` and `text-before-edge` are folded together: they differ by a fraction of
    /// the ascent that no avatar has ever depended on, and keeping them apart would mean
    /// carrying a hanging-baseline metric Core Text does not expose directly.
    enum Baseline: Sendable {
        case alphabetic
        case middle
        case central
        case hanging
        case textAfterEdge

        /// Parses `dominant-baseline`, defaulting to `alphabetic` — which covers `auto`,
        /// the initial value, and anything unrecognised.
        static func parse(_ text: String?) -> Baseline {
            switch text?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "middle": .middle
            case "central": .central
            case "hanging", "text-before-edge": .hanging
            case "text-after-edge": .textAfterEdge
            default: .alphabetic
            }
        }
    }
}

/// An sRGB colour parsed from an SVG paint value.
///
/// Stored as components rather than a `CGColor` so the parsed document stays `Equatable`
/// and `Sendable`, and so tests can assert on an exact colour without going through Core
/// Graphics.
struct SVGColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    /// SVG's initial `fill`, and the value used when an element names none.
    static let black = SVGColor(red: 0, green: 0, blue: 0, alpha: 1)

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Paint parsing

/// Declared in an extension so ``SVGColor`` keeps its memberwise initialiser: an `init`
/// in the main declaration would suppress it.
extension SVGColor {
    /// Parses an SVG paint value.
    ///
    /// Returns `nil` both for `none` and for anything outside the supported forms, so an
    /// element whose paint cannot be understood is skipped rather than drawn in a guessed
    /// colour. Supported: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()` with
    /// numbers or percentages, and the handful of keywords the generators actually emit.
    /// Gradients, patterns, and `url(#…)` references are not paints this understands.
    init?(paint text: String) {
        guard let color = Self.parse(text) else { return nil }
        self = color
    }

    private static let keywords: [String: SVGColor] = [
        "black": .black,
        "currentcolor": .black,
        "white": SVGColor(red: 1, green: 1, blue: 1, alpha: 1),
        "gray": SVGColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1),
        "grey": SVGColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1),
    ]

    private static func parse(_ text: String) -> SVGColor? {
        let token = text.trimmingCharacters(in: .whitespaces).lowercased()
        if token == "none" || token == "transparent" { return nil }
        if let keyword = keywords[token] { return keyword }
        if token.hasPrefix("#") { return hexadecimal(token.dropFirst()) }
        if token.hasPrefix("rgb") { return functional(token) }
        return nil
    }

    private static func hexadecimal(_ digits: Substring) -> SVGColor? {
        guard digits.allSatisfy(\.isASCII) else { return nil }
        let values = digits.compactMap(\.hexDigitValue)
        guard values.count == digits.count else { return nil }
        func short(_ index: Int) -> CGFloat { CGFloat(values[index]) / 15 }
        func long(_ index: Int) -> CGFloat { CGFloat(values[index] << 4 | values[index + 1]) / 255 }
        switch values.count {
        case 3: return SVGColor(red: short(0), green: short(1), blue: short(2), alpha: 1)
        case 4: return SVGColor(red: short(0), green: short(1), blue: short(2), alpha: short(3))
        case 6: return SVGColor(red: long(0), green: long(2), blue: long(4), alpha: 1)
        case 8: return SVGColor(red: long(0), green: long(2), blue: long(4), alpha: long(6))
        default: return nil
        }
    }

    private static func functional(_ token: String) -> SVGColor? {
        guard let open = token.firstIndex(of: "("), token.hasSuffix(")") else { return nil }
        let inside = token[token.index(after: open) ..< token.index(before: token.endIndex)]
        let parts = inside.split { $0 == "," || $0 == "/" || $0.isWhitespace }
        guard (3 ... 4).contains(parts.count) else { return nil }
        var channels: [CGFloat] = []
        for (index, part) in parts.enumerated() {
            guard let value = channel(part, isAlpha: index == 3) else { return nil }
            channels.append(value)
        }
        return SVGColor(
            red: channels[0],
            green: channels[1],
            blue: channels[2],
            alpha: channels.count == 4 ? channels[3] : 1
        )
    }

    /// One `rgb()` component, clamped into `0...1`. Colour channels are out of 255 and
    /// alpha out of 1 unless written as a percentage, which is out of 100 either way.
    private static func channel(_ text: Substring, isAlpha: Bool) -> CGFloat? {
        var token = text
        var isPercentage = false
        if token.hasSuffix("%") {
            isPercentage = true
            token.removeLast()
        }
        guard let value = Double(token), value.isFinite else { return nil }
        let divisor: Double = isPercentage ? 100 : (isAlpha ? 1 : 255)
        return CGFloat(min(max(value / divisor, 0), 1))
    }
}
