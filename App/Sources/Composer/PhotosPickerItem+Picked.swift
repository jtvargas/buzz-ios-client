import Foundation
import PhotosUI
// `PhotosPickerItem` is declared in the `_PhotosUI_SwiftUI` cross-import overlay,
// which is only brought in when *both* modules are imported in the same file. Without
// this line the type is not in scope, and the error says only that it cannot be found.
import SwiftUI

/// The photo library, as ``ComposerPickedItem``.
///
/// The whole of `PhotosUI`'s reach into this app is this file and the
/// `.photosPicker` modifier in ``MessageComposerView``. Everything after the bytes
/// arrive — the conversion, the upload, the strip, the send — is written against
/// the protocol, which is why a camera capture and a file import will be
/// conformances rather than a second pipeline.
///
/// `PHPickerViewController`, which `PhotosPicker` presents, runs out of process and
/// hands back only what was chosen, so **no photo-library permission is involved**
/// and there is no usage description to declare. That is a property of this picker
/// specifically: reading the library directly through `PHAsset` would need one.
extension PhotosPickerItem: ComposerPickedItem {
    /// Nothing. A picture is rendered rather than named, and the library's own
    /// filename is an implementation detail of the asset rather than something an
    /// author chose. A file import will have a real answer here.
    var suggestedFilename: String? { nil }

    /// The original bytes, in whatever format the library holds them — commonly
    /// HEIC on a device that took the photo itself. Asking for `Data` rather than
    /// an `Image` is deliberate: a decoded `Image` has already lost the question
    /// this app has to answer, which is what format the bytes were in.
    func loadData() async throws -> Data {
        guard let data = try await loadTransferable(type: Data.self) else {
            throw ComposerAttachmentError.emptyPick
        }
        return data
    }
}
