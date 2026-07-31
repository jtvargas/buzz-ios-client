@testable import BuzzKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The rules the relay enforces, asserted on bytes.
///
/// # Why these assert on segments and not on an upload
///
/// Because a green upload was exactly the evidence that was already in hand when this
/// shipped broken. The first version of the composer's picture path had a live test that
/// really did `PUT` a real picture at a real relay and really did pass — with a *generated*
/// picture, which carries no metadata. The owner's own photo library failed on the first
/// try.
///
/// So the assertions here name the thing the relay names: after a scrub there is no `APP1`,
/// no `APP2`, no `iCCP`, no `tEXt`. A test that only says "the relay took it" cannot
/// distinguish a picture that was clean from a relay that was lenient.
@Suite("Image metadata scrub")
struct ImageMetadataScrubTests {
    // MARK: - JPEG

    @Test("a photograph's EXIF, GPS and colour profile are all gone")
    func jpegLosesItsMetadata() throws {
        let photo = try #require(ImageFixture.jpeg(exif: true, wideGamut: true))
        // The premise: the fixture really is what a camera produces.
        #expect(JPEGSegments.markers(in: photo).contains(0xE1), "fixture carries no EXIF to remove")
        #expect(JPEGSegments.markers(in: photo).contains(0xE2), "fixture carries no colour profile to remove")

        let scrubbed = try ImageMetadataScrub.scrubJPEG(photo)
        let markers = JPEGSegments.markers(in: scrubbed)

        #expect(!markers.contains(0xE1), "EXIF survived")
        #expect(!markers.contains(0xE2), "the colour profile survived")
        for marker in UInt8(0xE1) ... UInt8(0xED) {
            #expect(!markers.contains(marker), "APP\(marker - 0xE0) survived")
        }
        #expect(!markers.contains(0xEF))
        #expect(!markers.contains(0xFE), "a comment survived")
    }

    /// The scrub must not eat the picture along with its provenance.
    @Test("the picture itself survives the scrub and still decodes")
    func jpegStillDecodes() throws {
        let photo = try #require(ImageFixture.jpeg(exif: true, wideGamut: true, width: 40, height: 24))

        let scrubbed = try ImageMetadataScrub.scrubJPEG(photo)
        let decoded = try #require(ImageFixture.decode(scrubbed))

        #expect(decoded.width == 40)
        #expect(decoded.height == 24)
        // The frame and scan headers are what a decoder needs; losing either would have
        // been caught above as a failure to decode, but naming them makes the intent clear.
        let markers = JPEGSegments.markers(in: scrubbed)
        #expect(markers.contains(0xDA), "the scan header was dropped")
    }

    /// `APP0`/`APP14` are the two the relay permits, and only in their canonical shape —
    /// an arbitrary payload under either would be a metadata channel left open.
    @Test("a forged JFIF header is dropped rather than trusted")
    func forgedJFIFIsDropped() throws {
        let clean = try #require(ImageFixture.jpeg())
        let forged = try JPEGSegments.inserting(
            marker: 0xE0,
            payload: Array("JFIF\0".utf8) + Array(repeating: 0x41, count: 40),
            into: clean
        )

        let scrubbed = try ImageMetadataScrub.scrubJPEG(forged)

        // The canonical one the encoder wrote may remain; the forged one may not, so the
        // scrubbed file must be no larger than the honest original.
        #expect(scrubbed.count <= clean.count)
        #expect(ImageFixture.decode(scrubbed) != nil)
    }

    @Test("bytes that are not a JPEG are refused rather than half-copied")
    func notAJPEG() {
        #expect(throws: ImageMetadataScrub.Failure.notJPEG) {
            try ImageMetadataScrub.scrubJPEG(Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    @Test("a JPEG that ends mid-segment is refused")
    func truncatedJPEG() throws {
        let photo = try #require(ImageFixture.jpeg())
        #expect(throws: (any Error).self) {
            try ImageMetadataScrub.scrubJPEG(photo.prefix(photo.count / 2))
        }
    }

    // MARK: - PNG

    @Test("a PNG loses its text chunks and its colour profile")
    func pngLosesItsMetadata() throws {
        let png = try #require(ImageFixture.png(text: true))
        #expect(PNGChunks.types(in: png).contains("tEXt"), "fixture carries no text chunk to remove")

        let scrubbed = try ImageMetadataScrub.scrubPNG(png)
        let types = PNGChunks.types(in: scrubbed)

        #expect(!types.contains("tEXt"))
        #expect(!types.contains("iTXt"))
        #expect(!types.contains("zTXt"))
        #expect(!types.contains("iCCP"))
        #expect(!types.contains("eXIf"))
        // The picture is still a picture.
        #expect(types.contains("IHDR"))
        #expect(types.contains("IDAT"))
        #expect(types.contains("IEND"))
        #expect(ImageFixture.decode(scrubbed) != nil)
    }

    /// The chunks that make an APNG animate are on the allowlist, which is what lets one
    /// function serve both kinds of PNG.
    @Test("an animated PNG keeps the chunks that animate it")
    func animatedPNGKeepsItsAnimation() throws {
        let apng = try PNGChunks.synthesisedAPNG()
        #expect(ImageMetadataScrub.isAnimatedPNG(apng))

        let scrubbed = try ImageMetadataScrub.scrubPNG(apng, isAnimated: true)
        let types = PNGChunks.types(in: scrubbed)

        #expect(types.contains("acTL"), "the animation control chunk was dropped")
        #expect(types.contains("fcTL"))
        #expect(types.contains("fdAT"))
        #expect(!types.contains("tEXt"))
        #expect(ImageMetadataScrub.isAnimatedPNG(scrubbed), "the result no longer reads as animated")
    }

    /// Refusing is the honest answer: the profile cannot come off without a decode, and a
    /// decode costs the animation.
    @Test("an animated PNG carrying a colour profile is refused, not flattened")
    func animatedPNGWithProfileIsRefused() throws {
        let apng = try PNGChunks.synthesisedAPNG(includeICCP: true)

        #expect(throws: ImageMetadataScrub.Failure.unremovableFromAnimation) {
            try ImageMetadataScrub.scrubPNG(apng, isAnimated: true)
        }
    }

    @Test("a still PNG is not mistaken for an animated one")
    func stillPNGIsNotAnimated() throws {
        let png = try #require(ImageFixture.png())
        #expect(!ImageMetadataScrub.isAnimatedPNG(png))
    }

    @Test("bytes that are not a PNG are refused")
    func notAPNG() {
        #expect(throws: ImageMetadataScrub.Failure.notPNG) {
            try ImageMetadataScrub.scrubPNG(Data([0x89, 0x00]))
        }
    }

    // MARK: - GIF

    @Test("a GIF loses its comment and keeps its frames and timing")
    func gifLosesItsComment() throws {
        let gif = try GIFBytes.animated(withComment: true)
        #expect(GIFBytes.hasComment(gif), "fixture carries no comment to remove")

        let scrubbed = try ImageMetadataScrub.scrubGIF(gif)

        #expect(!GIFBytes.hasComment(scrubbed))
        // Both frames and both graphic controls are still there — the animation is intact.
        #expect(GIFBytes.imageDescriptorCount(scrubbed) == 2)
        #expect(GIFBytes.graphicControlCount(scrubbed) == 2)
        #expect(scrubbed.last == 0x3B, "the trailer is missing")
    }

    @Test("a GIF loops the same number of times after the scrub")
    func gifKeepsItsLoop() throws {
        let gif = try GIFBytes.animated(withComment: true)
        let scrubbed = try ImageMetadataScrub.scrubGIF(gif)

        #expect(GIFBytes.hasNetscapeLoop(gif))
        #expect(GIFBytes.hasNetscapeLoop(scrubbed), "the loop extension was dropped")
    }

    @Test("bytes that are not a GIF are refused")
    func notAGIF() {
        #expect(throws: ImageMetadataScrub.Failure.notGIF) {
            try ImageMetadataScrub.scrubGIF(Data("GIF00000000000".utf8))
        }
    }

    // MARK: - WebP

    @Test("a WebP loses its EXIF chunk and clears the flag that advertised it")
    func webPLosesItsMetadata() throws {
        let webp = WebPBytes.animated(withEXIF: true)
        #expect(WebPBytes.chunkTypes(in: webp).contains("EXIF"), "fixture carries no EXIF to remove")

        let scrubbed = try ImageMetadataScrub.scrubWebP(webp)
        let types = WebPBytes.chunkTypes(in: scrubbed)

        #expect(!types.contains("EXIF"))
        #expect(types.contains("ANIM"), "the animation chunk was dropped")
        #expect(types.contains("ANMF"))
        // The VP8X feature byte must no longer claim metadata is present.
        let features = try #require(WebPBytes.vp8xFeatureByte(in: scrubbed))
        #expect(features & 0x08 == 0, "the EXIF flag is still set")
        #expect(features & 0x20 == 0, "the ICC flag is still set")
    }

    @Test("an animated WebP carrying a colour profile is refused, not flattened")
    func webPWithProfileIsRefused() {
        let webp = WebPBytes.animated(withICCP: true)

        #expect(throws: ImageMetadataScrub.Failure.unremovableFromAnimation) {
            try ImageMetadataScrub.scrubWebP(webp)
        }
    }

    @Test("an animated WebP is told apart from a still one")
    func animationDetection() {
        #expect(ImageMetadataScrub.isAnimatedWebP(WebPBytes.animated()))
        #expect(!ImageMetadataScrub.isAnimatedWebP(WebPBytes.still()))
    }

    @Test("bytes that are not a WebP are refused")
    func notAWebP() {
        #expect(throws: ImageMetadataScrub.Failure.notWebP) {
            try ImageMetadataScrub.scrubWebP(Data("RIFF____NOPE".utf8))
        }
    }
}
