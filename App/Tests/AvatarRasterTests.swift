import CoreGraphics
import Foundation
@testable import Hive
import Testing
import UIKit

/// The rasteriser: the viewBox-to-pixels mapping, the SVG alignment arithmetic that puts a
/// glyph where the document says, and one end-to-end render of the owner's real avatar
/// checked against its own pixels.
@Suite("Avatar raster")
struct AvatarRasterTests {
    /// The workspace owner's real avatar, decoded to its SVG source.
    static var ownerSVG: Data { AvatarRenderingTests.ownerSVG }

    /// The background the owner's avatar fills its circle with, `#FFF4CC`.
    static var ownerBackground: SVGColor { AvatarRenderingTests.ownerBackground }
}

extension AvatarRasterTests {
    @Test("the geometry fits the viewBox to the requested longest edge, keeping the aspect")
    func geometryFitsViewBox() throws {
        let square = try #require(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: 0, y: 0, width: 512, height: 512),
            pixelSize: 108
        ))
        #expect(square.size == CGSize(width: 108, height: 108))
        #expect(abs(square.scale - 108 / 512) < 1e-9)

        let wide = try #require(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: -10, y: -10, width: 200, height: 100),
            pixelSize: 100
        ))
        #expect(wide.size == CGSize(width: 100, height: 50))
        #expect(wide.origin == CGPoint(x: -10, y: -10))

        // Degenerate and non-finite boxes are the guard against an absurd allocation.
        #expect(SVGAvatarRenderer.Geometry(viewBox: .zero, pixelSize: 108) == nil)
        #expect(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 8),
            pixelSize: 108
        ) == nil)
        #expect(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: 0, y: 0, width: 8, height: 8),
            pixelSize: 0
        ) == nil)
        #expect(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: CGFloat.nan, y: 0, width: 8, height: 8),
            pixelSize: 108
        ) == nil)

        // And the boxes whose *derived* values are the non-finite ones, which the checks on
        // the declared edges cannot see: every edge here is finite and positive, and the
        // scale they divide into is not.
        #expect(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: 0, y: 0, width: 1e-308, height: 1e-308),
            pixelSize: 108
        ) == nil)
        #expect(SVGAvatarRenderer.Geometry(
            viewBox: CGRect(x: 0, y: 0, width: 1e-308, height: 5e-324),
            pixelSize: 108
        ) == nil)
    }

    @Test("a subnormal viewBox resolves to nil rather than reaching the renderer")
    func refusesSubnormalViewBox() {
        // End to end, because the parse accepts this document — `1e-308` is finite and
        // greater than zero, so it satisfies the viewBox grammar — and the geometry is the
        // only thing between it and `UIGraphicsImageRenderer` being handed a CGSize of
        // infinities.
        let source = ##"<svg viewBox="0 0 1e-308 1e-308"><rect width="1" height="1" fill="#000"/></svg>"##
        #expect(SVGAvatarDocument(data: Data(source.utf8)) != nil)
        #expect(SVGAvatarRenderer.image(svg: Data(source.utf8), pixelSize: 108) == nil)
    }

    @Test("text-anchor moves the run across its own advance width")
    func anchorsText() {
        let run = SVGTextRun(
            text: "x",
            origin: CGPoint(x: 100, y: 50),
            fontSize: 10,
            anchor: .start,
            baseline: .alphabetic,
            fill: .black
        )
        #expect(SVGAvatarRenderer.anchoredX(run, width: 40) == 100)
        var middle = run
        middle.anchor = .middle
        #expect(SVGAvatarRenderer.anchoredX(middle, width: 40) == 80)
        var end = run
        end.anchor = .end
        #expect(SVGAvatarRenderer.anchoredX(end, width: 40) == 60)
    }

    @Test("dominant-baseline shifts the baseline off the anchor, which is what centres it")
    func placesBaseline() {
        let font = UIFont.systemFont(ofSize: 54)
        var run = SVGTextRun(
            text: "x",
            origin: CGPoint(x: 0, y: 100),
            fontSize: 54,
            anchor: .middle,
            baseline: .alphabetic,
            fill: .black
        )
        let place = { (baseline: SVGTextRun.Baseline) -> CGFloat in
            run.baseline = baseline
            return SVGAvatarRenderer.baselineY(run, font: font, ascent: 50, descent: 12)
        }

        #expect(place(.alphabetic) == 100)
        // `middle` is the alignment the emoji template uses. Half an x-height below the
        // anchor is what pushes the glyph up into the centre of the tile; leaving it at the
        // anchor would sit it low.
        #expect(place(.middle) == 100 + font.xHeight / 2)
        #expect(place(.middle) > 100)
        #expect(place(.central) == 100 + CGFloat(50 - 12) / 2)
        #expect(place(.hanging) == CGFloat(150))
        #expect(place(.textAfterEdge) == CGFloat(88))
    }

    @Test("the owner's avatar rasterises to a filled circle with a glyph in it")
    func rendersOwnerAvatar() throws {
        let image = try #require(SVGAvatarRenderer.image(svg: Self.ownerSVG, pixelSize: 108))
        #expect(image.size == CGSize(width: 108, height: 108))

        let pixels = try Pixels(image)
        // `rx="256"` on a 512-square is a full circle, so the corners are outside it.
        #expect(pixels.alpha(column: 1, row: 1) < 0.05)
        #expect(pixels.alpha(column: 106, row: 106) < 0.05)
        // Top centre is inside the circle and above the glyph, so it is bare background.
        #expect(pixels.isApproximately(Self.ownerBackground, column: 54, row: 4))

        // And the glyph is really there: a solid block of pixels that are neither
        // transparent nor the background. Counted rather than sampled, so the assertion
        // does not depend on which part of a top hat lands on one coordinate.
        var ink = 0
        var background = 0
        for row in 0 ..< pixels.height {
            for column in 0 ..< pixels.width {
                guard pixels.alpha(column: column, row: row) > 0.9 else { continue }
                if pixels.isApproximately(Self.ownerBackground, column: column, row: row) {
                    background += 1
                } else {
                    ink += 1
                }
            }
        }
        #expect(background > 2000)
        #expect(ink > 1000)
    }

    @Test("a payload with nothing drawable in it renders nil, never a blank tile")
    func rendersNilForUnusablePayloads() {
        #expect(SVGAvatarRenderer.image(svg: Data(), pixelSize: 108) == nil)
        #expect(SVGAvatarRenderer.image(svg: Data("<svg viewBox='0 0 8 8'/>".utf8), pixelSize: 108) == nil)
        // Raster bytes are not a document, so the XML parse refuses them outright rather
        // than the renderer producing an empty tile.
        #expect(SVGAvatarRenderer.image(
            svg: AvatarRenderingTests.pngData(size: 32),
            pixelSize: 108
        ) == nil)
    }

    /// Reads back a rendered avatar's pixels as premultiplied sRGB.
    private struct Pixels {
        private let bytes: [UInt8]
        let width: Int
        let height: Int

        init(_ image: UIImage) throws {
            let cgImage = try #require(image.cgImage)
            let width = cgImage.width
            let height = cgImage.height
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            // The draw happens inside the pointer's scope: a `CGContext` built over
            // `&buffer` would outlive the pointer it was handed and read freed memory.
            try buffer.withUnsafeMutableBytes { raw in
                let context = try #require(CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.width = width
            self.height = height
            bytes = buffer
        }

        func alpha(column: Int, row: Int) -> CGFloat {
            CGFloat(bytes[(row * width + column) * 4 + 3]) / 255
        }

        /// Whether the pixel is `color`, within a tolerance that absorbs premultiplication
        /// and colour-space rounding.
        func isApproximately(_ color: SVGColor, column: Int, row: Int) -> Bool {
            let offset = (row * width + column) * 4
            let alpha = CGFloat(bytes[offset + 3]) / 255
            guard alpha > 0.9 else { return false }
            let channels = [color.red, color.green, color.blue]
            return (0 ..< 3).allSatisfy { index in
                abs(CGFloat(bytes[offset + index]) / 255 - channels[index]) < 0.03
            }
        }
    }
}
