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
    /// The kinds of avatar this editor makes. Buzz's desktop client has a tab this one does
    /// not — `Animated` — and this one has a tab desktop does not, ``avatarKit``.
    ///
    /// Last in the list on purpose: the two above it are what someone came here to do, and a
    /// build is what they stay for.
    enum Tab: Hashable, CaseIterable, Identifiable {
        case image
        case emoji
        case avatarKit

        var id: Self { self }

        var title: String {
            switch self {
            case .image: "Image"
            case .emoji: "Emoji"
            case .avatarKit: "AvatarKit"
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

    /// The avatar being built on the AvatarKit tab. Its own draft, for the reason at the
    /// top of this file: someone who wanders over to look around has not thrown away their
    /// photo, and someone who wanders back has not thrown away their build.
    ///
    /// Changing it drops the uploaded URL, because that URL is a picture of the *previous*
    /// combination. Leaving it would let Done save a face nobody is looking at.
    var avatarKitAvatar: AvatarKitAvatar {
        didSet {
            guard avatarKitAvatar != oldValue else { return }
            avatarKitURL = nil
            avatarKitError = nil
        }
    }

    /// The built avatar's artwork on the relay, once Done has put it there.
    private(set) var avatarKitURL: String?
    private(set) var isPreparingAvatarKit = false
    private(set) var avatarKitError: String?

    private let uploader: (any MediaUploading)?

    /// Seeds the editor from whatever the profile already holds.
    ///
    /// An emoji document opens on the emoji tab with its glyph and colour selected, so
    /// changing only the colour is two taps. Anything else that looks like artwork — an
    /// uploaded URL, or a data URI this app did not write — opens on the image tab, which
    /// is the honest place for "there is a picture here and it is not an emoji".
    ///
    /// # Why the built avatar is tested first, and by identity
    ///
    /// A built avatar publishes as an uploaded `https://` URL — the same *kind* of string a
    /// photo publishes as. Nothing in the value says which tab drew it, so the only honest
    /// test is whether this device is the one that put that exact URL there, which
    /// ``AvatarKitRecipeStore`` remembers. Being exact, it can never mistake a photo for a
    /// build; being first, it does not depend on the emoji parser's answer either.
    init(picture: String?, uploader: (any MediaUploading)?) {
        self.uploader = uploader

        // Never blank: an editor that opens on an empty box makes the reader shuffle before
        // they can judge anything, and the last thing they built is the better guess.
        let recipe = AvatarKitRecipeStore.load()
        avatarKitAvatar = recipe?.avatar ?? .random()

        if let picture, let recipe, recipe.publishedURL == picture {
            tab = .avatarKit
            avatarKitURL = picture
            emoji = nil
            color = EmojiAvatar.defaultColor
        } else if let picture, let existing = EmojiAvatar(dataURL: picture) {
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
        case .avatarKit:
            avatarKitURL
        }
    }

    /// Whether Done has anything to do. An upload in flight blocks it: the URL that would
    /// be saved does not exist yet.
    ///
    /// The built avatar answers differently because its picture does not exist *yet* rather
    /// than *not at all* — there is nothing to pick, so there is nothing to have not picked,
    /// and Done is what draws it. What blocks Done there is the drawing already running, and
    /// a photo upload on the other tab, which would otherwise finish into a value nobody
    /// asked to save.
    var canSave: Bool {
        switch tab {
        case .image, .emoji:
            pictureValue != nil && !isUploading
        case .avatarKit:
            !isUploading && !isPreparingAvatarKit
        }
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

    // MARK: - Publishing a built avatar

    /// Draws the built avatar, puts it on the relay, and hands back the URL Done should
    /// save — or `nil`, having said on the tab why not.
    ///
    /// # Why this waits until Done, when a photo does not
    ///
    /// A photo's upload has a moment of its own to sit in: the pick. A build has none. The
    /// avatar changes on every press of Shuffle, and a press meant to be repeated twenty
    /// times cannot have a relay round trip behind it. So the one wait goes where the one
    /// decision is, and the sheet stays up over it rather than dismissing and failing after
    /// the fact.
    func publishAvatarKit() async -> String? {
        isPreparingAvatarKit = true
        avatarKitError = nil
        defer { isPreparingAvatarKit = false }

        guard let uploader else {
            avatarKitError = "Can't save right now — you're not connected."
            return nil
        }

        let built = avatarKitAvatar
        do {
            let png = try AvatarKitExport.pngData(for: built)
            let blob = try await uploader.upload(
                data: png,
                mimeType: AvatarKitExport.mimeType,
                filename: nil
            )
            // The tab is disabled while this runs, so the avatar cannot have moved — this is
            // what keeps that a fact rather than an assumption, because the alternative is
            // saving a picture of a face the reader has already replaced.
            guard avatarKitAvatar == built else { return nil }
            avatarKitURL = blob.url
            // Recorded as a *publish* rather than as a save, because two questions are being
            // answered by the one write and only one of them is this editor's: which face to
            // open on next time, and — for anything that needs to recognise this app's own
            // work on a profile later — that this exact URL is that face. See
            // ``AvatarKitPublishedAvatar``.
            AvatarKitPublishedAvatar.record(built, publishedAs: blob.url)
            return blob.url
        } catch {
            avatarKitError = Self.avatarKitMessage(for: error)
            return nil
        }
    }

    /// What to say when a build could not be saved.
    ///
    /// Kept apart from ``message(for:)`` rather than folded into it, because that one speaks
    /// in terms of a photo — "try a different one" — and there is no different one here.
    private static func avatarKitMessage(for error: Error) -> String {
        switch error {
        case AvatarKitExport.Failure.couldNotDraw,
             AvatarKitExport.Failure.couldNotEncode:
            "That avatar couldn't be turned into a picture. Shuffle and try again."
        default:
            "Couldn't save that avatar. Please try again."
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
