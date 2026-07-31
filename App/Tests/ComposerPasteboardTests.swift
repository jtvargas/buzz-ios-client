import BuzzKit
import Foundation
@testable import Hive
import Testing
import UniformTypeIdentifiers

/// Pasting a picture into the composer.
///
/// # What this covers and what it cannot
///
/// The *rule* — which pasteboard items count as pictures, in what order, and what happens to
/// the ones that do not — is here, which is why it lives in its own type rather than inside
/// the text view. What is not here is the responder chain: whether the edit menu offers Paste
/// and whether `UITextView` gets the call is UIKit's, and asserting it would mean driving a
/// real keyboard menu.
@MainActor
@Suite("Composer pasteboard", .timeLimit(.minutes(1)))
struct ComposerPasteboardTests {
    private static func provider(_ data: Data, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @Test("a pasted picture yields its original bytes, not a re-encode")
    func pastedPictureKeepsItsBytes() async throws {
        let png = TestPicture.png()
        let providers = [Self.provider(png, type: .png)]

        let pictures = await ComposerPasteboard.images(from: providers)

        #expect(pictures.count == 1)
        // The bytes, unchanged — which is what lets the preparation step see the real format.
        // `UIPasteboard.image` would have handed back a decoded `UIImage` and lost it.
        #expect(pictures.first == png)
        #expect(ImageByteFormat.detect(try #require(pictures.first)) == .png)
    }

    @Test("several pasted pictures keep the order they were copied in")
    func orderIsPreserved() async throws {
        let first = TestPicture.png(width: 8, height: 8)
        let second = TestPicture.png(width: 16, height: 16)

        let pictures = await ComposerPasteboard.images(from: [
            Self.provider(first, type: .png),
            Self.provider(second, type: .png),
        ])

        #expect(pictures == [first, second])
    }

    /// A provider conforms to `public.image` for things this composer cannot prepare — a PDF
    /// page, a vector. Naming the formats explicitly is what keeps those out.
    @Test("something that is not a picture this app sends is skipped rather than attached")
    func nonPictureIsSkipped() async throws {
        let providers = [
            Self.provider(Data("%PDF-1.7".utf8), type: .pdf),
            Self.provider(TestPicture.png(), type: .png),
        ]

        let pictures = await ComposerPasteboard.images(from: providers)

        #expect(pictures.count == 1, "a non-picture was attached")
        #expect(ImageByteFormat.detect(try #require(pictures.first)) == .png)
    }

    @Test("an empty pasteboard attaches nothing")
    func emptyPasteboard() async throws {
        #expect(await ComposerPasteboard.images(from: []).isEmpty)
    }

    /// A paste goes through the same door as a pick, so it inherits the cap without the cap
    /// being restated — the property that makes the limit true rather than merely configured
    /// on the picker.
    @Test("a paste is bounded by the same five-picture cap as a pick")
    func pasteObeysTheCap() async throws {
        let model = ComposerAttachmentsModel(uploader: StubUploader())
        let pasted = (0 ..< 7).map { _ in PastedPicture(data: TestPicture.png()) }

        model.add(pasted)

        #expect(model.attachments.count == ComposerAttachmentsModel.selectionLimit)
        #expect(model.uploadError == "You can attach 5 pictures at a time.")
    }

    @Test("a pasted picture with no bytes is refused rather than attached")
    func emptyPasteIsRefused() async throws {
        await #expect(throws: ComposerAttachmentError.emptyPick) {
            try await PastedPicture(data: Data()).loadData()
        }
    }
}
