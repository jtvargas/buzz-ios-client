import BuzzKit
import Foundation
import Observation
import UIKit

/// The state behind the avatar editor: which kind of avatar is being made, the pieces it
/// is made of, and — for a photo — the upload that has to finish before there is anything
/// to save.
///
/// # Why the two kinds do not share a value
///
/// A profile's `picture` is one string, so an avatar is *either* an uploaded image URL or
/// an inline emoji document. But someone switching to the emoji tab to look around has not
/// thrown their photo away, and switching back must not have cost them the upload. So both
/// are held at once and the tab decides which one ``pictureValue`` is; only Done commits.
///
/// # Why the upload happens on pick rather than on Done
///
/// A photo has to be prepared and PUT to the relay before its URL exists, which on a slow
/// connection is seconds. Doing that on Done would mean a spinner over a sheet that looks
/// finished, with a failure arriving after the decision. Doing it on pick puts the wait
/// next to the action that caused it, and Done stays instant.
@MainActor
@Observable
final class ProfileAvatarEditorModel {
    /// The kinds of avatar this editor makes. Buzz's desktop client has a third tab,
    /// `Animated`, which is deliberately not here.
    enum Tab: Hashable, CaseIterable, Identifiable {
        case image
        case emoji

        var id: Self { self }

        var title: String {
            switch self {
            case .image: "Image"
            case .emoji: "Emoji"
            }
        }
    }

    var tab: Tab

    /// The chosen glyph, or `nil` when none has been. Nothing is preselected — matching
    /// desktop, and because a default glyph would be indistinguishable from a choice and
    /// would let Done publish an avatar nobody picked.
    private(set) var emoji: String?
    private(set) var color: String

    /// The uploaded artwork's URL, once there is one.
    private(set) var imageURL: String?
    /// A small JPEG of the picked photo, shown while the upload is in flight so the tab is
    /// not an empty box for the seconds it takes.
    private(set) var imagePreview: UIImage?

    private(set) var isUploading = false
    private(set) var uploadError: String?

    private let uploader: (any MediaUploading)?

    /// Seeds the editor from whatever the profile already holds.
    ///
    /// An emoji document opens on the emoji tab with its glyph and colour selected, so
    /// changing only the colour is two taps. Anything else that looks like artwork — an
    /// uploaded URL, or a data URI this app did not write — opens on the image tab, which
    /// is the honest place for "there is a picture here and it is not an emoji".
    init(picture: String?, uploader: (any MediaUploading)?) {
        self.uploader = uploader

        if let picture, let existing = EmojiAvatar(dataURL: picture) {
            tab = .emoji
            emoji = existing.emoji
            color = existing.color
        } else {
            tab = picture == nil ? .emoji : .image
            emoji = nil
            color = EmojiAvatar.defaultColor
            imageURL = picture
        }
    }

    // MARK: - Choosing

    func select(emoji: String) {
        self.emoji = emoji
    }

    func select(color: String) {
        self.color = color
    }

    /// Drops the photo, returning the image tab to its empty state. The emoji side is left
    /// alone: this is "not that picture", not "no avatar".
    func removeImage() {
        imageURL = nil
        imagePreview = nil
        uploadError = nil
    }

    // MARK: - Saving

    /// The `picture` value Done would write, or `nil` when this tab has nothing to save.
    ///
    /// Read rather than stored, so it cannot drift from the tab that is on screen.
    var pictureValue: String? {
        switch tab {
        case .image:
            imageURL
        case .emoji:
            emoji.map { EmojiAvatar(emoji: $0, color: color).dataURL() }
        }
    }

    /// Whether Done has anything to do. An upload in flight blocks it: the URL that would
    /// be saved does not exist yet.
    var canSave: Bool {
        pictureValue != nil && !isUploading
    }

    // MARK: - Uploading

    /// Prepares a picked photo and puts it on the relay, leaving ``imageURL`` set.
    ///
    /// The preparation is the composer's, unchanged and for the same reasons: it converts
    /// what the library holds into a format the relay stores, and — the part that matters
    /// on a photo of a person — strips the EXIF an iPhone writes, which carries GPS. An
    /// avatar is the most-published picture someone owns; it is the last one that should
    /// carry where it was taken.
    func upload(_ item: some ComposerPickedItem) async {
        isUploading = true
        uploadError = nil
        defer { isUploading = false }

        guard let uploader else {
            uploadError = "Can't upload right now — you're not connected."
            return
        }

        do {
            let prepared = try await ComposerImagePreparation.prepare(try await item.loadData())
            imagePreview = UIImage(data: prepared.preview)
            let blob = try await uploader.upload(
                data: prepared.data,
                mimeType: prepared.mimeType,
                filename: nil
            )
            imageURL = blob.url
            tab = .image
        } catch {
            // The preview is dropped with the failure: leaving it would show the photo
            // sitting in place as though it had been accepted.
            imagePreview = nil
            uploadError = Self.message(for: error)
        }
    }

    /// What to say about a failure, in terms of the thing that failed rather than the
    /// layer it failed in.
    private static func message(for error: Error) -> String {
        switch error {
        case ComposerImagePreparation.Failure.notAPicture:
            "That file isn't an image."
        case ComposerImagePreparation.Failure.couldNotConvert,
             ComposerImagePreparation.Failure.animationCannotBeCleaned:
            "That image couldn't be prepared. Try a different one."
        case ComposerAttachmentError.emptyPick:
            "That photo couldn't be read. Try a different one."
        default:
            "Couldn't upload that photo. Please try again."
        }
    }
}
