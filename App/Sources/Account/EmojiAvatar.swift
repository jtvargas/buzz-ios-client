import Foundation

/// An avatar built from one emoji on one flat colour — the form Buzz's own clients write
/// into a profile's `picture` field.
///
/// # Why a data URI and not an upload
///
/// Desktop uploads *raster* avatars to Blossom and stores the resulting `https://` URL, but
/// it deliberately keeps an emoji avatar inline as a percent-encoded SVG `data:` URI. That
/// makes it free to change, impossible to 404, and readable by a client that has never
/// spoken to the media server — which is why the workspace owner's own avatar is one of
/// these. ``SVGAvatarDocument`` already parses this exact document back into pixels; this
/// type is the other half, the one that writes it.
///
/// # Why the string is reproduced byte for byte
///
/// The output must equal `emojiAvatarDataUrl()` in
/// `desktop/src/features/profile/ui/ProfileAvatarEditor.utils.ts` exactly, because desktop
/// reads an avatar back by *matching the source text* (`parseEmojiAvatarDataUrl`) rather
/// than by rendering it. An avatar written here with the attributes in a different order,
/// a different font size, or a different percent-encoding still draws correctly on both
/// clients — and then opens on desktop with the emoji tab empty and the colour reset,
/// because the regex missed. So the layout below is fixed, not stylistic.
struct EmojiAvatar: Equatable, Sendable {
    /// The glyph drawn in the middle.
    var emoji: String
    /// The background, as an uppercase `#RRGGBB` string. Held as text rather than as a
    /// `Color` because it is round-tripped through the document verbatim.
    var color: String

    /// The corner the background is drawn with. Buzz writes people as circles; the rounded
    /// square exists because agent avatars use it, and reading one back must not fail.
    enum Shape: Sendable {
        case circle
        case roundedSquare

        /// The `rx` in the 512-unit document.
        var cornerRadius: Int {
            switch self {
            case .circle: 256
            case .roundedSquare: 112
            }
        }
    }
}

// MARK: - Writing

extension EmojiAvatar {
    /// Everything before the payload. A URI without it is not one of ours.
    static let dataURLPrefix = "data:image/svg+xml,"

    /// The glyph's size in the 512-unit viewBox. Desktop's constant, not a tuned one.
    static let fontSize = 258

    /// The document this avatar is stored as: a `data:` URI holding one `<rect>` and one
    /// `<text>`, percent-encoded the way `encodeURIComponent` encodes it.
    func dataURL(shape: Shape = .circle) -> String {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">\
        <rect width="512" height="512" rx="\(shape.cornerRadius)" fill="\(color)"/>\
        <text x="50%" y="56%" dominant-baseline="middle" text-anchor="middle" \
        font-size="\(Self.fontSize)">\(Self.escapingXML(emoji))</text></svg>
        """
        return Self.dataURLPrefix + Self.percentEncoding(svg)
    }

    /// The three characters that would otherwise close the element early. Emoji need none
    /// of this; it is here because desktop escapes, and an avatar has to survive whatever
    /// a picker hands over.
    private static func escapingXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The characters `encodeURIComponent` leaves alone: ASCII letters and digits plus
    /// `-_.!~*'()`.
    ///
    /// Spelled out rather than taken from `CharacterSet.alphanumerics`, which is a *Unicode*
    /// set — it holds `é` and `一`, which `encodeURIComponent` does encode. Starting from it
    /// would produce a URI that renders identically here and fails desktop's match.
    private static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "A" ... "Z")
        set.formUnion(CharacterSet(charactersIn: "a" ... "z"))
        set.formUnion(CharacterSet(charactersIn: "0" ... "9"))
        set.formUnion(CharacterSet(charactersIn: "-_.!~*'()"))
        return set
    }()

    private static func percentEncoding(_ text: String) -> String {
        // The set is a closed ASCII literal, so there is no input this can refuse.
        text.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? text
    }
}

// MARK: - Reading

extension EmojiAvatar {
    /// The avatar a stored `picture` value describes, or `nil` when it is an uploaded
    /// image, a remote URL, or anything else this does not recognise.
    ///
    /// Matched the same way desktop matches it — against the decoded source text — so the
    /// two clients agree on which avatars are editable as emoji. Anything that decodes but
    /// does not match is *not* an error: it is a picture, and the editor opens on the image
    /// tab instead.
    init?(dataURL: String) {
        guard dataURL.hasPrefix(Self.dataURLPrefix) else { return nil }
        let payload = String(dataURL.dropFirst(Self.dataURLPrefix.count))
        guard let svg = payload.removingPercentEncoding,
              let color = Self.attribute("fill", ofElement: "rect", in: svg),
              let emoji = Self.textContent(in: svg)
        else { return nil }
        self.color = color
        self.emoji = Self.unescapingXML(emoji)
    }

    /// The value of a double-quoted attribute on the first element with the given name.
    ///
    /// A scan rather than a regex: the corpus is one generator's output, and the scan says
    /// what it accepts in the order it accepts it.
    private static func attribute(_ name: String, ofElement element: String, in svg: String) -> String? {
        guard let elementStart = svg.range(of: "<\(element) "),
              let elementEnd = svg.range(of: ">", range: elementStart.upperBound ..< svg.endIndex)
        else { return nil }
        let body = svg[elementStart.upperBound ..< elementEnd.lowerBound]
        guard let valueStart = body.range(of: "\(name)=\""),
              let valueEnd = body.range(of: "\"", range: valueStart.upperBound ..< body.endIndex)
        else { return nil }
        return String(body[valueStart.upperBound ..< valueEnd.lowerBound])
    }

    /// What sits between the first `<text …>` and its `</text>`.
    private static func textContent(in svg: String) -> String? {
        guard let openStart = svg.range(of: "<text "),
              let openEnd = svg.range(of: ">", range: openStart.upperBound ..< svg.endIndex),
              let close = svg.range(of: "</text>", range: openEnd.upperBound ..< svg.endIndex)
        else { return nil }
        return String(svg[openEnd.upperBound ..< close.lowerBound])
    }

    /// The inverse of ``escapingXML(_:)``. `&amp;` is undone last, so `&amp;lt;` survives
    /// the round trip as the text `&lt;` rather than collapsing into `<`.
    private static func unescapingXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Palette

extension EmojiAvatar {
    /// The background swatches, in the order the picker draws them.
    ///
    /// Buzz's palette verbatim (`AVATAR_COLORS`), so a colour chosen on the phone is one
    /// desktop shows as selected rather than as a custom value. Any other colour is still
    /// valid — the editor's colour well writes one — this is just the set that gets a tile.
    static let palette = [
        "#FFFFFF", "#FFF4CC", "#FFE75C", "#FFB84D",
        "#FF8652", "#F6534F", "#FF6B9A", "#FB60C4",
        "#D66BFF", "#B141FF", "#7C5CFF", "#476CFF",
        "#3399FF", "#63C6F2", "#41EBC1", "#2ED3A2",
        "#73EF75", "#9FE870", "#C7D36F", "#CCCCCC",
        "#8A8F98", "#4B5563", "#000000",
    ]

    /// What a fresh emoji avatar starts as, matching desktop's default.
    static let defaultColor = "#FFFFFF"
}
