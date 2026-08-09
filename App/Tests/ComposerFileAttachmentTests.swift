import BuzzKit
import Foundation
@testable import Hive
import Testing

/// What the composer does with a file, as distinct from a picture.
///
/// The interesting cases are all about the *seam*: one pipeline now carries two kinds
/// of thing, and each test below pins a place where treating them alike would be
/// wrong — or, in ``photoPickedThroughFilesIsStillScrubbed``, a place where treating
/// them differently would be.
@MainActor
@Suite("Composer file attachments", .timeLimit(.minutes(1)))
struct ComposerFileAttachmentTests {
    /// Bounded, and it falls through on expiry rather than trapping, so a failure
    /// prints the `#expect` that actually failed instead of a timeout.
    static func waitUntil(
        _ condition: @MainActor () async -> Bool,
        within seconds: Double = 5
    ) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Bytes ImageIO cannot open — a stand-in for every document.
    static func documentBytes() -> Data {
        Data("%PDF-1.4\nnot really a pdf, but nothing can decode it as a picture\n".utf8)
    }

    // MARK: - The document path

    @Test("A file that is not a picture becomes a ready attachment")
    func documentBecomesAttachment() async {
        let model = ComposerAttachmentsModel()
        model.add([StubPickedItem(
            data: Self.documentBytes(),
            suggestedFilename: "report.pdf",
            isDocument: true
        )])
        await Self.waitUntil { !model.isAttaching }

        #expect(model.attachments.count == 1)
        let attachment = try? #require(model.attachments.first)
        #expect(attachment?.isReady == true)
        // The name is what the tile draws and what the message's link is labelled
        // with, so it has to survive the whole pipeline.
        #expect(attachment?.localPayload?.filename == "report.pdf")
        // Nothing to draw: a file has no preview, which is exactly how the strip
        // decides to draw a document tile instead of a blank picture.
        #expect(attachment?.preview == nil)
        #expect(attachment?.documentName == "report.pdf")
    }

    /// The same bytes from the photo library are still a failure.
    ///
    /// This is the pair to the test above and the reason ``ComposerPickedItem/isDocument``
    /// exists at all: what changed is the *source*, not the pipeline.
    @Test("The same bytes from the photo library still fail")
    func photoPickOfNonPictureStillFails() async {
        let model = ComposerAttachmentsModel()
        model.add([StubPickedItem(data: Self.documentBytes(), suggestedFilename: nil)])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.uploadError == "That file isn't a picture.")
    }

    /// A photo reached through *Files* still goes through the picture pipeline.
    ///
    /// The privacy property, and the one worth a test of its own: EXIF on an iPhone
    /// photo carries GPS, and ``ComposerImagePreparation`` is what strips it. Routing
    /// documents around that step would have left one of the two ways to attach the
    /// same photo publishing where it was taken.
    @Test("A photo picked through Files is still scrubbed")
    func photoPickedThroughFilesIsStillScrubbed() async {
        let model = ComposerAttachmentsModel()
        model.add([StubPickedItem(
            data: TestPicture.png(),
            suggestedFilename: "holiday.png",
            isDocument: true
        )])
        await Self.waitUntil { !model.isAttaching }

        let attachment = try? #require(model.attachments.first)
        // An image MIME rather than `application/octet-stream` is the evidence: only
        // the picture route assigns one.
        #expect(attachment?.localPayload?.mimeType == "image/png")
        // And it drew a thumbnail, which the document route never does.
        #expect(attachment?.preview != nil)
    }

    @Test("A file counts against the same five-item limit as a picture")
    func filesShareTheAttachmentLimit() async {
        let model = ComposerAttachmentsModel()
        model.add((0 ..< 6).map {
            StubPickedItem(
                data: Self.documentBytes(),
                suggestedFilename: "doc-\($0).pdf",
                isDocument: true
            )
        })
        await Self.waitUntil { !model.isAttaching }

        #expect(model.attachments.count == ComposerAttachmentsModel.selectionLimit)
        #expect(model.uploadError == "You can attach 5 items at a time.")
    }

    // MARK: - The policy mirror

    /// The local pre-check mirrors the relay rather than inventing a rule.
    ///
    /// Each of these is a line in `buzz-media/src/validation.rs`; the point of
    /// checking them here is that the *author* is told at pick time instead of after
    /// a hundred megabytes have gone up.
    @Test("Blocked types and oversized files are refused before any upload")
    func policyMirrorsTheRelay() {
        #expect(MediaUploadClient.policyFailure(mimeType: "application/pdf", byteCount: 1_024) == nil)
        #expect(MediaUploadClient.policyFailure(mimeType: "text/csv", byteCount: 1_024) == nil)
        #expect(
            MediaUploadClient.policyFailure(mimeType: "text/html", byteCount: 1_024)
                == .unsupportedType("text/html")
        )
        #expect(
            MediaUploadClient.policyFailure(mimeType: "image/svg+xml", byteCount: 1_024)
                == .unsupportedType("image/svg+xml")
        )
        let over = MediaUploadClient.maxFileBytes + 1
        #expect(
            MediaUploadClient.policyFailure(mimeType: "application/zip", byteCount: over)
                == .tooLarge(bytes: over, max: MediaUploadClient.maxFileBytes)
        )
    }

    /// Audio is refused by the relay and deliberately *not* by this list.
    ///
    /// Pinned because the absence is a decision rather than an oversight: the relay
    /// sniffs bytes, and a local refusal keyed on a declared type would block files
    /// the platform would have taken.
    @Test("Audio is left to the relay to refuse")
    func audioIsNotRefusedLocally() {
        #expect(MediaUploadClient.policyFailure(mimeType: "audio/mpeg", byteCount: 1_024) == nil)
    }

    // MARK: - The type a file declares

    @Test("A file's type comes from its extension, falling back to opaque bytes")
    func mimeTypeComesFromTheExtension() {
        #expect(ComposerFilePick(url: URL(fileURLWithPath: "/tmp/a.pdf")).mimeType == "application/pdf")
        #expect(ComposerFilePick(url: URL(fileURLWithPath: "/tmp/a.json")).mimeType == "application/json")
        // No extension, and nothing to guess from: the relay sniffs the bytes anyway.
        #expect(
            ComposerFilePick(url: URL(fileURLWithPath: "/tmp/whatever")).mimeType
                == "application/octet-stream"
        )
    }

    @Test("A file's suggested name is its last path component")
    func filenameIsTheLastPathComponent() {
        let pick = ComposerFilePick(url: URL(fileURLWithPath: "/tmp/deep/Q3 report.pdf"))
        #expect(pick.suggestedFilename == "Q3 report.pdf")
        #expect(pick.isDocument)
    }
}
