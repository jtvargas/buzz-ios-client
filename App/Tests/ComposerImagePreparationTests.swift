import BuzzKit
import Foundation
@testable import Hive
import Testing
import UIKit

/// What happens to a picture's bytes between the picker and the relay.
@MainActor
@Suite("Composer image preparation", .timeLimit(.minutes(1)))
struct ComposerImagePreparationTests {
    /// The rule that replaced "a format the relay stores is not touched", which is what
    /// this file used to assert and what the owner's photo library disproved within
    /// minutes of the build reaching his phone.
    ///
    /// The relay stores those formats *bare*. A PNG that arrived carrying a text chunk
    /// is still a PNG when it leaves, and the chunk is not.
    @Test("a stored format is still cleaned rather than passed through")
    func storedFormatIsCleaned() async throws {
        let original = TestPicture.pngWithMetadata()

        let prepared = try await ComposerImagePreparation.prepare(original)

        #expect(prepared.mimeType == "image/png")
        #expect(prepared.data != original, "the picture went up exactly as it arrived")
        #expect(ImageByteFormat.detect(prepared.data) == .png)
        #expect(!prepared.preview.isEmpty)
    }

    /// A photograph, which is the case that was failing: EXIF and a colour profile, both
    /// refused by the relay, and one of them carrying GPS.
    @Test("a photograph loses its EXIF and its colour profile")
    func photographIsStripped() async throws {
        let photo = try #require(TestPicture.photoJPEG())

        let prepared = try await ComposerImagePreparation.prepare(photo)

        #expect(prepared.mimeType == "image/jpeg")
        let markers = TestPicture.jpegMarkers(in: prepared.data)
        #expect(!markers.contains(0xE1), "EXIF survived to the relay")
        #expect(!markers.contains(0xE2), "the colour profile survived to the relay")
        #expect(UIImage(data: prepared.data) != nil, "the result is not a decodable picture")
    }

    /// The HEIC branch, exercised through TIFF — the same "the relay will not store
    /// this" path, without needing a HEIC encoder on the machine running the tests.
    @Test("a format the relay will not store is converted to JPEG")
    func unsupportedFormatIsConverted() async throws {
        let original = try #require(TestPicture.tiff())

        let prepared = try await ComposerImagePreparation.prepare(original)

        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.data != original)
        #expect(ImageByteFormat.detect(prepared.data) == .jpeg)
    }

    /// An animation must survive as an animation. A decode-and-re-encode would return one
    /// frame and report success, which is the failure this routing exists to avoid.
    @Test("an animated GIF is scrubbed without being flattened")
    func animatedGIFStaysAnimated() async throws {
        let gif = TestPicture.animatedGIF()

        let prepared = try await ComposerImagePreparation.prepare(gif)

        #expect(prepared.mimeType == "image/gif")
        #expect(ImageByteFormat.detect(prepared.data) == .gif)
        #expect(TestPicture.gifFrameCount(in: prepared.data) == 2, "the animation was flattened")
    }

    /// The subtle one, and the reason the conversion goes through `UIImage` rather
    /// than straight from the `CGImage`: a photo shot in portrait is landscape
    /// pixels plus a rotation tag. An encoder handed the pixels alone publishes it
    /// on its side, and nothing downstream can put it back.
    ///
    /// The source is 40×20 with orientation 6 (rotate 90°), so an upright result is
    /// 20×40. A conversion that dropped the rotation would come out 40×20.
    @Test("a rotation in the metadata is baked into the converted pixels")
    func orientationIsApplied() async throws {
        let rotated = try #require(TestPicture.tiff(width: 40, height: 20, orientation: 6))
        // The premise: the file really does declare a quarter turn.
        #expect(UIImage(data: rotated)?.imageOrientation != .up)

        let prepared = try await ComposerImagePreparation.prepare(rotated)
        let converted = try #require(UIImage(data: prepared.data)?.cgImage)

        #expect(converted.width == 20)
        #expect(converted.height == 40)
    }

    /// Same source without the rotation tag, so the dimensions above are the
    /// rotation being applied rather than a coincidence of the fixture.
    @Test("an upright picture keeps its dimensions through the conversion")
    func uprightPictureIsUnrotated() async throws {
        let upright = try #require(TestPicture.tiff(width: 40, height: 20))

        let prepared = try await ComposerImagePreparation.prepare(upright)
        let converted = try #require(UIImage(data: prepared.data)?.cgImage)

        #expect(converted.width == 40)
        #expect(converted.height == 20)
    }

    @Test("bytes that are not a picture are refused")
    func notAPicture() async throws {
        await #expect(throws: ComposerImagePreparation.Failure.notAPicture) {
            try await ComposerImagePreparation.prepare(Data("not a picture at all".utf8))
        }
    }

    /// The preview is a real, decodable picture — it is what the strip draws, and a
    /// tile that cannot decode its own thumbnail shows an empty box.
    @Test("the preview decodes and is no larger than the tile needs")
    func previewIsUsable() async throws {
        let prepared = try await ComposerImagePreparation.prepare(TestPicture.png(width: 1200, height: 900))
        let preview = try #require(UIImage(data: prepared.preview)?.cgImage)

        #expect(max(preview.width, preview.height) <= Int(ComposerImagePreparation.previewPixelSize))
        // Downsampled, not the original re-wrapped.
        #expect(preview.width < 1200)
    }
}
