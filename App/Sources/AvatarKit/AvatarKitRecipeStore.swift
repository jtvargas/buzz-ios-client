import Foundation

/// Where the built avatar is remembered between visits to the editor.
///
/// # Why this is not the profile
///
/// What gets published is a URL to a picture. The *recipe* — which hair, which outfit — is
/// not in it and cannot be got back out of it, so an editor that only had the profile to go
/// on would open on a stranger every time and the reader would have to rebuild before they
/// could adjust. So the recipe stays on the device that made it.
///
/// # Why `UserDefaults`
///
/// This is a preference, not data. It is one small value, it belongs to this device rather
/// than to the identity, and losing it costs a shuffle. The app's durable store is a
/// projection rebuilt from the verified event log — the wrong shape for something no event
/// will ever carry.
enum AvatarKitRecipeStore {
    /// The avatar last built, and the URL the last successful publish of it returned.
    ///
    /// The URL is kept for one purpose: recognising this app's own work on the way back in.
    /// A published AvatarKit avatar is an uploaded `https://` URL, which is character for
    /// character the same *kind* of string a photo publishes as — nothing about the value
    /// says which tab made it. Matching against the URL this device was handed is the only
    /// honest test, and it is exact, so it can never mistake a photo for a build.
    struct Recipe: Codable, Equatable, Sendable {
        var avatar: AvatarKitAvatar
        var publishedURL: String?
    }

    private static let key = "avatarkit.recipe"

    /// The saved recipe, or `nil` when there is none this version can read.
    ///
    /// A recipe written by a later version — a background this one has no case for, say —
    /// fails to decode and is treated as absent rather than as a failure. The cost of that
    /// is one shuffle; the cost of throwing would be an editor that will not open.
    static func load(from defaults: UserDefaults = .standard) -> Recipe? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Recipe.self, from: data)
    }

    /// Remembers `recipe`, silently on failure: a preference that would not encode is not
    /// worth interrupting a save for.
    static func save(_ recipe: Recipe, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: key)
    }
}
