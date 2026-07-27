import Foundation
import Observation

/// The conversations this reader has starred, held on this device.
///
/// # Why local, and only local
///
/// A star is a statement about how one person uses one phone — which three rooms they
/// want at the top of their own list. It is not a fact about the conversation, nobody
/// else can act on it, and publishing it would put a readable list of what someone cares
/// about on a relay for no benefit to anyone. So it stays in `UserDefaults`, beside the
/// section-expansion flags, and never leaves the device. (This is also what JT asked
/// for: "Store starred items locally on the device.")
///
/// # Why an object rather than `@AppStorage`
///
/// `@AppStorage` binds one value to one view. A star is toggled from a swipe on a row
/// and read by the grouping that decides which heading that row sits under — two places,
/// one truth — and the set has to survive both being re-created on every body pass.
/// Holding it in one `@Observable` object injected through the environment means the
/// toggle and the grouping cannot disagree, and it makes the persistence testable
/// against a scratch `UserDefaults` instead of the app's real one.
@MainActor
@Observable
final class StarredConversations {
    /// The starred conversation ids. A set, because the only questions asked of it are
    /// "is this one starred" and "which of these rows are" — order inside the Starred
    /// heading is the sidebar's ordinary newest-first rule, not the order stars were
    /// added.
    private(set) var ids: Set<String> = []

    /// The `UserDefaults` key behind the list.
    ///
    /// Pinned by a test for the same reason the expansion keys are: renaming it silently
    /// discards every star an existing install has set, and nothing else would catch it.
    static let storageKey = "sidebar.starred.conversations"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read through `stringArray(forKey:)` rather than `array(forKey:)`: a defaults
        // value written by some future version of this app with a different shape then
        // reads as nil and the reader starts with no stars, instead of trapping on a
        // failed cast at launch.
        ids = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isStarred(_ id: String) -> Bool { ids.contains(id) }

    /// Stars a conversation, or removes the star. Persisted immediately — there is no
    /// later moment at which a star is committed, and an app killed from the switcher a
    /// second after the swipe must not lose it.
    func toggle(_ id: String) {
        guard !id.isEmpty else { return }
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        // Sorted, so the stored array is stable across writes. Nothing reads the order,
        // but an unstable one turns every toggle into a diff of the whole list for
        // anything that ever inspects the defaults (a backup, a support dump).
        defaults.set(ids.sorted(), forKey: Self.storageKey)
    }
}
