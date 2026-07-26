import CoreGraphics
import Foundation
@testable import Hive
import Testing
import UIKit

/// The decode half of the avatar pipeline: ImageIO's downsample against real bytes, and
/// the SVG subset that stands in for the decoder ImageIO does not have.
@Suite("Avatar rendering")
struct AvatarRenderingTests {
    /// The workspace owner's real avatar, decoded to its SVG source.
    static var ownerSVG: Data { Data(AvatarSourceTests.ownerAvatarSVG.utf8) }

    /// The background the owner's avatar fills its circle with, `#FFF4CC`.
    static let ownerBackground = SVGColor(red: 1, green: 244 / 255, blue: 204 / 255, alpha: 1)

    /// A real PNG of `size` pixels square, filled with `color` — bytes built here rather
    /// than checked in, so the downsample is exercised against something a decoder must
    /// genuinely parse.
    static func pngData(size: CGFloat, color: UIColor = .systemTeal) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
            .image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size, height: size))
                // A second colour so the result is not uniform, and a resize that silently
                // produced a blank bitmap would be visible.
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
            }
        return image.pngData() ?? Data()
    }
}

// MARK: - ImageIO downsample

extension AvatarRenderingTests {
    @Test("a large source decodes straight to the requested pixel size, never larger")
    func downsamplesToRequestedSize() throws {
        let data = Self.pngData(size: 1254)
        #expect(data.count > 1000)

        let thumbnail = try #require(AvatarLoader.downsample(data, maxPixelSize: 108))
        #expect(thumbnail.size == CGSize(width: 108, height: 108))
        // The point of the exercise: the decoded bitmap is the tile, not the source. A
        // 1254-square would be 6.3 MB; this is 47 KB.
        let bitmap = try #require(thumbnail.cgImage)
        #expect(bitmap.bytesPerRow * bitmap.height < 64 * 1024)
    }

    @Test("a source smaller than the request is not upscaled")
    func doesNotUpscale() throws {
        let thumbnail = try #require(AvatarLoader.downsample(Self.pngData(size: 64), maxPixelSize: 320))
        #expect(thumbnail.size == CGSize(width: 64, height: 64))
    }

    @Test("bytes no decoder can read produce nil, including the relay's 404 body")
    func rejectsUndecodableBytes() {
        #expect(AvatarLoader.downsample(Data(), maxPixelSize: 108) == nil)
        #expect(AvatarLoader.downsample(Data(#"{"error":"not_found"}"#.utf8), maxPixelSize: 108) == nil)
        #expect(AvatarLoader.downsample(Data([0xDE, 0xAD, 0xBE, 0xEF]), maxPixelSize: 108) == nil)
        // The diagnosis in one assertion: ImageIO ships no SVG decoder, so the owner's
        // avatar is invisible to this path no matter how it is delivered.
        #expect(AvatarLoader.downsample(Self.ownerSVG, maxPixelSize: 108) == nil)
    }
}

// MARK: - SVG parsing

extension AvatarRenderingTests {
    @Test("the owner's avatar parses to exactly the rect and text it is made of")
    func parsesOwnerAvatar() throws {
        let document = try #require(SVGAvatarDocument(data: Self.ownerSVG))

        #expect(document.viewBox == CGRect(x: 0, y: 0, width: 512, height: 512))
        #expect(document.elements.count == 2)

        guard case let .rectangle(frame, corner, fill) = document.elements[0] else {
            Issue.record("expected a rectangle first, got \(document.elements[0])")
            return
        }
        #expect(frame == CGRect(x: 0, y: 0, width: 512, height: 512))
        // A lone `rx` has to be mirrored into `ry`, or the tile is a capsule not a circle.
        #expect(corner == CGSize(width: 256, height: 256))
        #expect(fill == Self.ownerBackground)

        guard case let .text(run) = document.elements[1] else {
            Issue.record("expected text second, got \(document.elements[1])")
            return
        }
        #expect(run.text == "\u{1F3A9}")
        #expect(run.fontSize == 258)
        #expect(run.anchor == .middle)
        #expect(run.baseline == .middle)
        #expect(run.fill == .black) // no `fill` attribute, so SVG's initial black
        // `x="50%"`, `y="56%"` resolved against the 512-square viewBox.
        #expect(run.origin.x == 256)
        #expect(abs(run.origin.y - 286.72) < 0.01)
    }

    @Test("a document that cannot render resolves to nil instead of hanging")
    func rejectsUnusableDocuments() {
        // Empty, and not XML at all.
        #expect(SVGAvatarDocument(data: Data()) == nil)
        #expect(SVGAvatarDocument(data: Data([0xFF, 0xD8, 0xFF])) == nil)
        // Well-formed XML that is not an SVG with anything drawable in it.
        #expect(SVGAvatarDocument(data: Data("<html><body/></html>".utf8)) == nil)
        #expect(SVGAvatarDocument(data: Data(#"<svg viewBox="0 0 8 8"/>"#.utf8)) == nil)
        // An SVG with no usable coordinate system, so its rect has nothing to sit in.
        #expect(SVGAvatarDocument(data: Data("<svg><rect width='4' height='4'/></svg>".utf8)) == nil)
        // Malformed XML.
        #expect(SVGAvatarDocument(data: Data("<svg viewBox='0 0 8 8'><rect".utf8)) == nil)
        // Over the byte cap.
        let padding = String(repeating: " ", count: SVGAvatarDocument.maximumByteCount)
        #expect(SVGAvatarDocument(data: Data("<svg viewBox='0 0 8 8'>\(padding)</svg>".utf8)) == nil)
    }

    @Test("a document type declaration is refused outright, so entity expansion cannot run")
    func refusesDoctype() {
        let bomb = """
        <?xml version="1.0"?>
        <!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>
        <svg viewBox="0 0 8 8"><rect width="8" height="8" fill="#000"/><text>&b;</text></svg>
        """
        #expect(SVGAvatarDocument(data: Data(bomb.utf8)) == nil)
    }

    @Test("width and height stand in for a missing viewBox, and percentages do not")
    func viewBoxFallback() {
        #expect(SVGAvatarDocument.viewBox(from: ["viewbox": "0 0 512 512"])
            == CGRect(x: 0, y: 0, width: 512, height: 512))
        // Commas are legal separators, and a non-zero origin is carried through.
        #expect(SVGAvatarDocument.viewBox(from: ["viewbox": "-4,-4, 16 ,16"])
            == CGRect(x: -4, y: -4, width: 16, height: 16))
        #expect(SVGAvatarDocument.viewBox(from: ["width": "64", "height": "32"])
            == CGRect(x: 0, y: 0, width: 64, height: 32))
        // A percentage on the root has nothing to resolve against.
        #expect(SVGAvatarDocument.viewBox(from: ["width": "100%", "height": "100%"]) == nil)
        #expect(SVGAvatarDocument.viewBox(from: ["viewbox": "0 0 0 0"]) == nil)
        #expect(SVGAvatarDocument.viewBox(from: ["viewbox": "0 0 nope 8"]) == nil)
        #expect(SVGAvatarDocument.viewBox(from: [:]) == nil)
    }

    @Test("the length grammar takes user units, px, and percentages, and nothing else")
    func lengthGrammar() {
        #expect(SVGAvatarDocument.length("512", percentOf: 100) == 512)
        #expect(SVGAvatarDocument.length(" -12.5 ", percentOf: 100) == -12.5)
        #expect(SVGAvatarDocument.length("24px", percentOf: 100) == 24)
        #expect(SVGAvatarDocument.length("50%", percentOf: 512) == 256)
        #expect(SVGAvatarDocument.length("1e2", percentOf: 100) == 100)
        // Units this does not model are refused rather than approximated.
        #expect(SVGAvatarDocument.length("2em", percentOf: 100) == nil)
        #expect(SVGAvatarDocument.length("10mm", percentOf: 100) == nil)
        #expect(SVGAvatarDocument.length("abc", percentOf: 100) == nil)
        #expect(SVGAvatarDocument.length("", percentOf: 100) == nil)
        #expect(SVGAvatarDocument.length(nil, percentOf: 100) == nil)
        #expect(SVGAvatarDocument.length("inf", percentOf: 100) == nil)
    }

    @Test("shapes, alignment keywords, and defs are read the way SVG defines them")
    func parsesShapesAndKeywords() throws {
        let source = """
        <svg viewBox="0 0 100 100">
          <defs><rect width="100" height="100" fill="#f00"/></defs>
          <circle cx="50" cy="50" r="25" fill="#0f0"/>
          <ellipse cx="10" cy="20" rx="5" ry="8" fill="none"/>
          <rect width="100%" height="50%" fill="rgba(0, 0, 0, 0.5)"/>
          <text x="1" y="2" text-anchor="END" dominant-baseline="text-after-edge">hi</text>
        </svg>
        """
        let document = try #require(SVGAvatarDocument(data: Data(source.utf8)))

        // The `<defs>` rect is a definition, not a drawing, and `fill="none"` means the
        // ellipse is not painted — so three elements, not five.
        #expect(document.elements.count == 3)
        #expect(document.elements[0] == .ellipse(
            frame: CGRect(x: 25, y: 25, width: 50, height: 50),
            fill: SVGColor(red: 0, green: 1, blue: 0, alpha: 1)
        ))
        #expect(document.elements[1] == .rectangle(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            corner: .zero,
            fill: SVGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        ))
        guard case let .text(run) = document.elements[2] else {
            Issue.record("expected text last, got \(document.elements[2])")
            return
        }
        #expect(run.anchor == .end)
        #expect(run.baseline == .textAfterEdge)
        #expect(run.fontSize == 16) // CSS's initial size, since none was declared
    }

    @Test("a hostile document is bounded: elements are capped and text is truncated")
    func enforcesCaps() throws {
        // Doubled delimiters because the payload contains `"#`, which would close a
        // single-hash raw literal at `fill="#000"`.
        let shapes = String(
            repeating: ##"<rect width="1" height="1" fill="#000"/>"##,
            count: SVGAvatarDocument.maximumElementCount + 40
        )
        let long = String(repeating: "x", count: SVGAvatarDocument.maximumTextLength * 10)
        let source = #"<svg viewBox="0 0 8 8">"# + shapes + "<text>\(long)</text></svg>"
        let document = try #require(SVGAvatarDocument(data: Data(source.utf8)))
        #expect(document.elements.count == SVGAvatarDocument.maximumElementCount)

        let capped = try #require(SVGAvatarDocument(
            data: Data((#"<svg viewBox="0 0 8 8"><text>"# + long + "</text></svg>").utf8)
        ))
        guard case let .text(run) = capped.elements[0] else {
            Issue.record("expected text, got \(capped.elements[0])")
            return
        }
        #expect(run.text.count == SVGAvatarDocument.maximumTextLength)

        // A font size an order of magnitude past the canvas is clamped, not honoured.
        let huge = try #require(SVGAvatarDocument(data: Data(
            #"<svg viewBox="0 0 8 8"><text font-size="1e9">x</text></svg>"#.utf8
        )))
        guard case let .text(clamped) = huge.elements[0] else {
            Issue.record("expected text, got \(huge.elements[0])")
            return
        }
        #expect(clamped.fontSize == SVGAvatarDocument.maximumFontSizeRatio * 8)
    }

    @Test("a run of combining marks is bounded, though it is a single Character long")
    func boundsCombiningMarks() throws {
        // One base character and forty thousand combining acute accents: a bounded-looking
        // payload — well inside the byte cap, one element, and `text.count == 1` — that a
        // cap counted in `Character`s cannot see at all. It truncated nothing, and asking a
        // growing string for its `count` once per parser chunk made the guard itself
        // quadratic in the payload: 1.27 s of measured CPU for a 260 KB document.
        let padding = String(repeating: "\u{0301}", count: 40_000)
        #expect(padding.count == 1) // the premise: forty thousand scalars, one grapheme
        let source = #"<svg viewBox="0 0 8 8"><text>x"# + padding + "</text></svg>"
        #expect(Data(source.utf8).count < SVGAvatarDocument.maximumByteCount)

        let document = try #require(SVGAvatarDocument(data: Data(source.utf8)))
        guard case let .text(run) = document.elements[0] else {
            Issue.record("expected text, got \(document.elements[0])")
            return
        }
        // Truncated by scalar, which is the quantity Core Text has to shape. Asserted on the
        // scalars for the same reason the cap counts them: `hasPrefix("x")` is a grapheme
        // comparison, and the base character with its accents on is not the letter `x`.
        #expect(run.text.unicodeScalars.count == SVGAvatarDocument.maximumTextLength)
        #expect(run.text.unicodeScalars.first == "x")
        // And it is still one grapheme cluster, which is exactly why counting those was
        // the wrong bound.
        #expect(run.text.count == 1)
    }

    @Test("a nested <svg> inside <defs> cannot establish the coordinate system")
    func suppressedRootDoesNotSetTheViewBox() {
        // The only `viewBox` in the document is inside a definition, so there is no
        // coordinate system for the rect after it to be expressed in and nothing is drawn —
        // rather than the rect being measured against a box that describes a template
        // nobody referenced.
        let hidden = #"<svg><defs><svg viewBox="0 0 8 8"/></defs>"# +
            ##"<rect width="8" height="8" fill="#000"/></svg>"##
        #expect(SVGAvatarDocument(data: Data(hidden.utf8)) == nil)

        // A real root still wins, and a later nested one still does not replace it.
        let source = #"<svg viewBox="0 0 100 100"><defs><svg viewBox="0 0 8 8"/></defs>"# +
            ##"<rect width="50%" height="50%" fill="#000"/></svg>"##
        let document = SVGAvatarDocument(data: Data(source.utf8))
        #expect(document?.viewBox == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(document?.elements == [.rectangle(
            frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            corner: .zero,
            fill: SVGColor(red: 0, green: 0, blue: 0, alpha: 1)
        )])
    }
}

// MARK: - Paint

extension AvatarRenderingTests {
    @Test("the paint grammar covers the forms the generators emit, and refuses the rest")
    func parsesPaint() {
        #expect(SVGColor(paint: "#FFF4CC") == Self.ownerBackground)
        #expect(SVGColor(paint: "#fff") == SVGColor(red: 1, green: 1, blue: 1, alpha: 1))
        #expect(SVGColor(paint: "#0000") == SVGColor(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(SVGColor(paint: "#00000080")?.alpha == CGFloat(128) / 255)
        #expect(SVGColor(paint: " WHITE ") == SVGColor(red: 1, green: 1, blue: 1, alpha: 1))
        #expect(SVGColor(paint: "currentColor") == .black)
        #expect(SVGColor(paint: "rgb(255, 0, 0)") == SVGColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(SVGColor(paint: "rgb(100%, 0%, 0%)") == SVGColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(SVGColor(paint: "rgba(0,0,0,0.25)")?.alpha == 0.25)
        // Out-of-range channels clamp rather than producing an invalid colour.
        #expect(SVGColor(paint: "rgb(300, -20, 0)") == SVGColor(red: 1, green: 0, blue: 0, alpha: 1))

        // `none` and unsupported paints both mean "do not draw", which is why they share an
        // answer: a gradient reference is not something this can approximate.
        #expect(SVGColor(paint: "none") == nil)
        #expect(SVGColor(paint: "transparent") == nil)
        #expect(SVGColor(paint: "url(#gradient)") == nil)
        #expect(SVGColor(paint: "#12345") == nil)
        #expect(SVGColor(paint: "#gggggg") == nil)
        #expect(SVGColor(paint: "rgb(1, 2)") == nil)
        #expect(SVGColor(paint: "hotpink") == nil)
        #expect(SVGColor(paint: "") == nil)
    }
}
