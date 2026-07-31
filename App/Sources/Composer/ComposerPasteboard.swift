import Foundation
import UIKit
import UniformTypeIdentifiers

/// The text field, taught that a pasted picture is an attachment rather than text.
///
/// # Why a subclass and not a gesture or a menu item
///
/// Paste is a system action. `UIResponder.paste(_:)` is what the edit menu, the keyboard
/// shortcut, and the three-finger gesture all end up calling, and `canPerformAction` is what
/// decides whether the menu offers it at all. Intercepting there means every one of those
/// routes works without being handled separately — and a paste of *text* still falls through
/// to `UITextView`'s own behaviour untouched.
///
/// # Why the bytes and not `UIPasteboard.image`
///
/// `UIPasteboard.image` hands back a decoded `UIImage`, which has already thrown away the one
/// thing the pipeline needs to know: what format the bytes were in. A screenshot pasted as a
/// PNG and a photo pasted as a JPEG take different routes through
/// ``ComposerImagePreparation``, and an animated GIF must never be decoded at all. So this
/// reads the item providers and asks for data.
final class ComposerTextView: UITextView {
    /// Handed the pasted pictures, in the order the pasteboard holds them.
    var onPasteImages: (([Data]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), ComposerPasteboard.hasImages(.general) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard ComposerPasteboard.hasImages(.general) else {
            super.paste(sender)
            return
        }
        // Text alongside the picture is still text: a copied web selection carries both, and
        // dropping the words because a picture came with them would be a surprise.
        if UIPasteboard.general.hasStrings { super.paste(sender) }

        let providers = UIPasteboard.general.itemProviders
        Task { @MainActor [weak self] in
            let pictures = await ComposerPasteboard.images(from: providers)
            guard !pictures.isEmpty else { return }
            self?.onPasteImages?(pictures)
        }
    }
}

/// Reading pictures off the pasteboard.
///
/// Split from the view so the rule — which providers count, and in what order — is testable
/// without a responder chain.
///
/// `@MainActor` because `NSItemProvider` is not `Sendable` and the pasteboard is read from the
/// main actor anyway: pinning it here is what lets the providers be passed at all, and it is
/// honest about where a paste actually comes from. The loads themselves complete on whatever
/// queue UIKit chooses, which the continuation bridges.
@MainActor
enum ComposerPasteboard {
    /// The types worth taking. Deliberately the four the relay stores plus HEIC, rather than
    /// `UTType.image` alone: a provider will happily conform to `image` for a PDF page or a
    /// vector, and those are not pictures this composer can prepare.
    static let acceptedTypes: [UTType] = [.jpeg, .png, .gif, .webP, .heic, .heif]

    static func hasImages(_ pasteboard: UIPasteboard) -> Bool {
        // `hasImages` is the cheap check the menu can afford on every keystroke; the provider
        // walk below is the accurate one, and it runs only once a paste is actually asked for.
        pasteboard.hasImages
    }

    /// The picture bytes each provider can produce, in order, skipping any it cannot.
    ///
    /// Sequential rather than concurrent on purpose: a paste is one or two pictures, the loads
    /// are local, and the order the author copied them in is the order they should appear.
    static func images(from providers: [NSItemProvider]) async -> [Data] {
        var pictures: [Data] = []
        for provider in providers {
            guard let type = acceptedTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) else { continue }
            if let data = await data(from: provider, as: type) { pictures.append(data) }
        }
        return pictures
    }

    private static func data(from provider: NSItemProvider, as type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// A picture that arrived on the pasteboard, as ``ComposerPickedItem``.
///
/// The whole reason that protocol exists: a paste is a third source alongside the picker and
/// (later) the camera, and everything after the bytes — the scrub, the upload, the strip, the
/// cap — is written against it and does not change.
struct PastedPicture: ComposerPickedItem {
    let data: Data

    /// Nothing. The pasteboard rarely carries a name, and a picture is rendered rather than
    /// named — the same answer ``PhotosPickerItem`` gives.
    var suggestedFilename: String? { nil }

    func loadData() async throws -> Data {
        guard !data.isEmpty else { throw ComposerAttachmentError.emptyPick }
        return data
    }
}
