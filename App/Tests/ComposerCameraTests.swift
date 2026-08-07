import Foundation
@testable import Hive
import Testing

@MainActor
@Suite("Composer camera")
struct ComposerCameraTests {
    @Test("a capture is a picked item with the camera bytes and no filename")
    func captureUsesTheAttachmentSeam() async throws {
        let bytes = TestPicture.png()
        let capture = ComposerCameraCapture(data: bytes)

        #expect(capture.suggestedFilename == nil)
        #expect(try await capture.loadData() == bytes)
    }

    @Test("an empty capture is refused before the upload pipeline")
    func emptyCaptureIsRefused() async {
        await #expect(throws: ComposerAttachmentError.emptyPick) {
            try await ComposerCameraCapture(data: Data()).loadData()
        }
    }

    @Test("camera presentation declares a composer height change")
    func presentationChangesTheBarRevision() {
        let model = ComposerAttachmentsModel()
        let closed = model.barRevision

        model.presentCamera()

        #expect(model.isCameraPresented)
        #expect(model.barRevision != closed)

        model.dismissCamera()
        #expect(!model.isCameraPresented)
        #expect(model.barRevision == closed)
    }

    @Test("a full composer reports capacity instead of opening the camera")
    func capacityStopsPresentation() {
        let model = ComposerAttachmentsModel(uploader: { StubUploader() })
        model.add((0 ..< ComposerAttachmentsModel.selectionLimit).map { _ in
            StubPickedItem(data: TestPicture.png())
        })

        model.presentCamera()

        #expect(!model.isCameraPresented)
        #expect(model.uploadError == "You can attach 5 pictures at a time.")
        model.reset()
    }

    @Test("the panel geometry matches the approved 440-point layout")
    func geometry() {
        #expect(440 - 2 * ComposerCameraPanel.horizontalInset == 416)
        #expect(ComposerCameraPanel.height == 308)
        #expect(ComposerCameraPanel.cornerRadius == 15)
        #expect(ComposerCameraPanel.shutterDiameter == 64)
        #expect(ComposerCameraPanel.shutterStroke == 3)
        #expect(ComposerCameraPanel.shutterGap == 4)
        #expect(ComposerCameraPanel.shutterDiscDiameter == 50)
        #expect(ComposerCameraPanel.shutterBottomInset == 12)
        #expect(ComposerCameraPanel.closeGlyph == 10)
        #expect(ComposerCameraPanel.closeTarget / 2 + ComposerCameraPanel.closeTrailingInset == 26)
        #expect(ComposerCameraPanel.closeTarget / 2 == 22)
    }

    @Test("camera is a built attachment source")
    func cameraSourceIsBuilt() {
        #expect(ComposerAttachmentSource.camera.isBuilt)
    }
}
