import Foundation
#if DEBUG
import UIKit
#endif

/// Whether the picture a profile is publishing *right now* is one this app drew — and, when it
/// is, the recipe that will draw it again.
///
/// # Why this is a different question from "has anyone built an avatar"
///
/// ``AvatarKitRecipeStore`` answers "what was last built", which is the question the editor
/// asks when it opens: there has to be a face on the build tab whether or not it was ever
/// saved. This asks the other one — "is the avatar on this profile this app's own work" — and
/// the two part company the moment somebody builds a face and then publishes a photo instead.
/// Answering the first where the second was meant offers a reader an avatar they are not
/// wearing.
///
/// # Why it is the published string that is matched, and matched exactly
///
/// From the account editor a built avatar is published the way a photo is: drawn, `PUT`, and
/// the URL kept. Character for character it is the same *kind* of string, and nothing in the
/// value says which tab made it — so the only honest test is whether this device is the one
/// that put that exact string there. Being an equality it can never mistake a photo for a
/// build, and it also answers *no* the moment the picture becomes something else, without
/// having to be told that it did.
///
/// The arrival walk publishes a `data:` URI instead (§ ``AppEnvironment/publishableValue(for:)``)
/// and needs no other rule: an equality does not care which shape of string it is comparing.
///
/// # Why there is no second store under this name
///
/// The pair this needs — the URL that went out, and the avatar that produced it — is already
/// exactly what ``AvatarKitRecipeStore/Recipe`` holds, and every path that publishes one
/// already writes it. A second copy under a second key would be a second thing to keep in
/// step, and the failure that produces is the quiet kind: a row offering the face the editor
/// no longer agrees is the published one. So this is a name for the question rather than a
/// place to keep the answer.
enum AvatarKitPublishedAvatar {
    /// Records that `avatar` went out as `url`.
    ///
    /// The one call a publishing path has to make for the picture it just published to be
    /// recognisable as this app's work afterwards. Named as a sentence about publishing rather
    /// than about storage, because the *fact* is what matters and where it is kept is this
    /// file's business.
    ///
    /// `url` is optional because a publish can end with nothing having gone out at all — an
    /// avatar the renderer could not draw, or one dropped by the arrival walk's last-resort
    /// ceiling check — and recording `nil` is how that is said. It leaves the built face for the
    /// editor to open on while leaving the profile unclaimed, which is the truth in that case.
    static func record(_ avatar: AvatarKitAvatar, publishedAs url: String?) {
        AvatarKitRecipeStore.save(.init(avatar: avatar, publishedURL: url))
    }
}

// MARK: - Getting one back out

#if DEBUG
extension AvatarKitPublishedAvatar {
    /// The avatar `picture` was drawn from, or `nil` when this device did not draw it.
    ///
    /// Both `nil`s are rejected rather than compared. A profile with no picture at all and a
    /// recipe whose publish never landed would otherwise match each other — `nil == nil` — and
    /// claim an avatar that was never worn.
    static func recipe(
        forPublished picture: String?,
        in defaults: UserDefaults = .standard
    ) -> AvatarKitAvatar? {
        guard let picture,
              let recipe = AvatarKitRecipeStore.load(from: defaults),
              let published = recipe.publishedURL,
              published == picture
        else { return nil }
        return recipe.avatar
    }

    /// The name the exported file carries, which is the name whatever receives it shows.
    ///
    /// Said here rather than left to the encoder, because the alternative is an `image.png` in
    /// a Files listing beside every other app's `image.png`. The extension is the load-bearing
    /// half: it is how the share sheet decides which apps can accept the picture at all.
    static let exportFilename = "Hive Avatar.png"

    /// A finished export: the file the share sheet is pointed at, and the same bitmap for the
    /// thumbnail it draws while the reader is choosing where the picture is going.
    struct Export {
        let file: URL
        /// `nil` only if bytes this app has just encoded will not decode — a bug in the
        /// encoder rather than a state to handle, so the sheet falls back to a symbol instead
        /// of refusing to open.
        let image: UIImage?
    }

    /// Draws `avatar` and writes it where the share sheet can reach it.
    ///
    /// # Why a file rather than the bitmap
    ///
    /// ``MessageMediaExport``'s reason, unchanged: `ShareLink` over a file URL gives every
    /// receiver a real name and a real type — Mail attaches a `.png`, Files saves one — where
    /// an in-memory `UIImage` arrives re-encoded and anonymous.
    ///
    /// # Why it is drawn again rather than downloaded
    ///
    /// The published URL is right there and fetching it looks like the obvious move. But the
    /// bytes on the host are the *same* bytes — the recipe is what produced them and
    /// ``AvatarKitExport`` is a pure function of it — so drawing costs milliseconds, needs no
    /// network on a media host that is tailnet-only, and cannot hand back a 404 for a face the
    /// reader is looking at.
    @MainActor
    static func export(_ avatar: AvatarKitAvatar) throws -> Export {
        let png = try AvatarKitExport.pngData(for: avatar)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvatarKitExport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(exportFilename)
        // Always the same name, and replacing what is there is the point rather than a
        // collision to avoid: anything already at it is a picture of a face that is no longer
        // the published one. Atomic, so a share sheet opened over a half-written file cannot
        // happen. The system's temporary directory is purged for us and nothing here is worth
        // surviving a launch.
        try png.write(to: file, options: .atomic)
        return Export(file: file, image: UIImage(data: png))
    }
}
#endif
