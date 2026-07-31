import BuzzKit
import Foundation
@testable import Hive
import Testing
import UIKit

/// What happens to a picture's bytes between the picker and the relay.
@MainActor
@Suite("Composer image preparation", .timeLimit(.minutes(1)))
struct ComposerImagePreparationTests {
    /// A format the relay stores goes up exactly as it arrived. This is what keeps
    /// an animated GIF animated: a re-encode would flatten it to one frame and
    /// report success.
    @Test("a format the relay stores is not touched")
    func storedFormatPassesThrough() async throws {
        let original = TestPicture.png()

        let prepared = try await ComposerImagePreparation.prepare(original)

        #expect(prepared.mimeType == "image/png")
        #expect(prepared.data == original)
        #expect(!prepared.preview.isEmpty)
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
