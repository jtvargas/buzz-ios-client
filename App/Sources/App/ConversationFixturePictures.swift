#if DEBUG
import Foundation
import UIKit

/// The pictures ``ConversationFixture`` can hang off a conversation, drawn here rather
/// than fetched.
///
/// Kept out of `ConversationFixture.swift` because it is a *different* kind of thing: that
/// file is about the shape of a conversation — how many messages, how tall, where it rests
/// — and this one is about drawing a bitmap. Splitting them is also what keeps either
/// under the 400-line rule.
extension ConversationFixture {
    /// One message per picture shape, drawn here rather than fetched: a `data:` URI is a
    /// picture with no network behind it, which is what lets the viewer be looked at on a
    /// machine that cannot reach the relay.
    ///
    /// The shapes are the ones the viewer's fit has to answer for: taller than the screen,
    /// wider than it, neither, and the two extremes at either end where a fit that is even
    /// slightly wrong is obvious. Each is drawn with a border and a mark in every corner,
    /// so a screenshot says whether the whole picture is on screen — a missing corner is a
    /// crop.
    ///
    /// `Light` is the odd one out and is not about the fit at all. The header pill is
    /// glass, and glass is only ever as legible as what is behind it, so the sampler has
    /// to contain the case that breaks it: a near-white field under the pill's own corner.
    /// One shape of the sampler.
    struct PictureShape {
        let name: String
        let size: CGSize
        let colour: UIColor
    }

    /// The shapes, in the order they are hung off the conversation. `Pair` is not here —
    /// it is a message of *two* pictures, and is appended after these.
    static let pictureShapes: [PictureShape] = [
        PictureShape(
            name: "Tall", size: CGSize(width: 900, height: 1600),
            colour: UIColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1)
        ),
        PictureShape(
            name: "Wide", size: CGSize(width: 1600, height: 700),
            colour: UIColor(red: 0.40, green: 0.20, blue: 0.16, alpha: 1)
        ),
        PictureShape(
            name: "Square", size: CGSize(width: 1200, height: 1200),
            colour: UIColor(red: 0.16, green: 0.34, blue: 0.24, alpha: 1)
        ),
        PictureShape(
            name: "Panorama", size: CGSize(width: 2400, height: 600),
            colour: UIColor(red: 0.12, green: 0.30, blue: 0.36, alpha: 1)
        ),
        PictureShape(
            name: "Column", size: CGSize(width: 800, height: 2400),
            colour: UIColor(red: 0.34, green: 0.16, blue: 0.34, alpha: 1)
        ),
        // Tall, and that is the point of it: the pill is at the *top* of the screen, so a
        // wide picture is letterboxed away from it and the glass ends up over black —
        // which answers nothing. Only a picture that reaches the top can.
        PictureShape(
            name: "Light", size: CGSize(width: 1000, height: 1700),
            colour: UIColor(white: 0.94, alpha: 1)
        ),
        PictureShape(
            name: "Small", size: CGSize(width: 320, height: 240),
            colour: UIColor(red: 0.52, green: 0.38, blue: 0.10, alpha: 1)
        ),
    ]

    /// The sampler, or the single shape `only` names.
    ///
    /// An unrecognised name yields nothing rather than trapping — the parser's own rule.
    static func pictureSampler(only: String? = nil) -> [String] {
        let wanted = only?.lowercased()
        let singles = pictureShapes
            .filter { wanted == nil || $0.name.lowercased() == wanted }
            .map { "![\($0.name) picture](\(pictureDataURI(size: $0.size, colour: $0.colour)))" }
        guard wanted == nil || wanted == "pair" else { return singles }
        return singles + [picturePair]
    }

    /// One message carrying two pictures, which is the other way into the viewer: a mosaic
    /// cell opens a *gallery* rather than a single picture, and the header has to survive
    /// the paging chrome that comes with it.
    static var picturePair: String {
        let tall = pictureDataURI(
            size: CGSize(width: 1000, height: 1400),
            colour: UIColor(red: 0.30, green: 0.24, blue: 0.44, alpha: 1)
        )
        let wide = pictureDataURI(
            size: CGSize(width: 1400, height: 1000),
            colour: UIColor(red: 0.44, green: 0.36, blue: 0.14, alpha: 1)
        )
        return "![Pair one](\(tall)) ![Pair two](\(wide))"
    }

    /// A `data:` PNG of `size`, deterministic for a given size and colour.
    ///
    /// The border and the corner marks are drawn in whichever of white or near-black the
    /// fill is furthest from — a white mark on the `Light` picture would be no mark at
    /// all, and the marks are the only reason a screenshot can be read.
    static func pictureDataURI(size: CGSize, colour: UIColor) -> String {
        var brightness: CGFloat = 0
        colour.getWhite(&brightness, alpha: nil)
        let ink: UIColor = brightness > 0.5 ? UIColor(white: 0.12, alpha: 1) : .white
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ink.setStroke()
            let inset = min(size.width, size.height) * 0.02
            let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
            border.lineWidth = inset
            border.stroke()
            ink.setFill()
            let mark = min(size.width, size.height) * 0.12
            for left in [inset * 2, size.width - inset * 2 - mark] {
                for top in [inset * 2, size.height - inset * 2 - mark] {
                    context.fill(CGRect(x: left, y: top, width: mark, height: mark))
                }
            }
        }
        guard let data = image.pngData() else { return "" }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}
#endif
