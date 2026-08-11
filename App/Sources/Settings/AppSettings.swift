import Foundation
import Observation

/// The preferences that belong to the *app* rather than to any one community.
///
/// # Why these are not per-community
///
/// Almost everything in Hive is scoped to a community: the store, the engine, the key, the
/// sidebar. These are the exceptions — a reader who has turned alerts off has turned them off
/// on this phone, not in one of three relays, and a phone that asked the same question once per
/// community would be asking about a switch iOS only has one of. So this object is built by
/// ``AppEnvironment``, which outlives the per-community graph, and survives a community switch
/// untouched.
///
/// # Why `UserDefaults` and not the relay
///
/// The same reasoning as ``StarredConversations``: a preference is a statement about how one
/// person uses one phone. Publishing it would put it on a relay for nobody's benefit, and it
/// would then have to be reconciled against a second device that disagrees. Local, and only
/// local.
///
/// # Adding the next one
///
/// One stored property with a `didSet` that writes it, and one key beside the others. Nothing
/// else — ``SettingsView`` draws a row per setting and no registry has to learn about it. A
/// setting that is not a `Bool` reads through its own `defaults` accessor in `init` the way
/// ``notificationsEnabled`` reads through ``flag(_:default:)``; the point of the helper is the
/// **default**, which `UserDefaults.bool(forKey:)` cannot express — it answers `false` for a key
/// nobody has written, and a preference that silently starts off on a phone that has been
/// upgrading fine is a feature that has quietly stopped working.
@MainActor
@Observable
final class AppSettings {
    /// Whether Hive may raise a notification at all.
    ///
    /// Today that means the alert a Later reminder fires, which is the only notification this
    /// app schedules (``ReminderScheduler``). It is deliberately phrased as the *app's* switch
    /// rather than the reminder feature's: it is enforced at the one place every alert is
    /// scheduled, so anything added later is covered by the same switch without being wired to
    /// it again.
    ///
    /// **On by default**, for installs that have been firing reminders since before this
    /// screen existed.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// Which ``HiveTheme`` the app draws — the ground on every screen, and the accent.
    ///
    /// Stored as the theme's id rather than its index, so re-ordering the catalogue or dropping a
    /// theme cannot silently hand somebody a different colour than the one they chose. An id that
    /// no longer names anything resolves back to ``HiveTheme/hive`` (``HiveTheme/named(_:)``).
    ///
    /// Defaults to `Hive`, which is the ground and amber the app has always drawn, so an install
    /// that never opens the picker is unchanged.
    var themeID: String {
        didSet {
            defaults.set(themeID, forKey: Key.themeID)
            HiveThemeBox.shared.theme = theme
        }
    }

    /// Whether a thread reply leaves the agents it addressed in the composer, ready for the
    /// next one.
    ///
    /// It changes nothing about what is sent: the follow-up still carries a real `@mention`
    /// and a real `p` tag, because that tag is what the relay filters an agent's subscription
    /// on. All this decides is whether the reader has to retype the name every turn.
    ///
    /// **Off by default.** A mention the author did not type is a message going somewhere they
    /// did not choose, so this is opt-in rather than something an upgrade switches on for them.
    var keepAgentsMentioned: Bool {
        didSet { defaults.set(keepAgentsMentioned, forKey: Key.keepAgentsMentioned) }
    }

    /// The chosen theme itself. Resolved rather than stored so ``themeID`` stays the single
    /// source of truth and the two cannot drift.
    ///
    /// Mirrored into ``HiveThemeBox`` on every write — including the one in ``init(defaults:)``,
    /// since `didSet` does not fire during initialisation. That box is what the accent call
    /// sites read, and it exists because most of them cannot reach this object: they are
    /// `static` colours on style types and UIKit's window tint. This stays the source of truth
    /// and the box stays a mirror of it; the writes are here so there is exactly one writer.
    var theme: HiveTheme { .named(themeID) }

    /// The `UserDefaults` keys, in one place and pinned by a test.
    ///
    /// Renaming one silently resets that preference for every existing install, and — unlike a
    /// renamed symbol — nothing in the compiler notices.
    enum Key {
        static let notificationsEnabled = "settings.notifications.enabled"
        static let themeID = "settings.theme.id"
        static let keepAgentsMentioned = "settings.composer.keepAgentsMentioned"
    }

    private let defaults: UserDefaults

    /// `defaults` is injectable so the persistence can be exercised against a scratch suite
    /// rather than the app's real preferences — the same seam ``StarredConversations`` takes.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notificationsEnabled = Self.flag(Key.notificationsEnabled, default: true, in: defaults)
        themeID = defaults.string(forKey: Key.themeID) ?? HiveTheme.hive.id
        keepAgentsMentioned = Self.flag(Key.keepAgentsMentioned, default: false, in: defaults)
        // `didSet` does not fire for a write inside `init`, so the launch value has to be
        // mirrored by hand — without this, an app relaunched on a chosen theme draws its ground
        // correctly (that comes through the environment) and every accent in the amber.
        HiveThemeBox.shared.theme = theme
    }

    /// A stored `Bool` with a default that applies only when nobody has written one.
    ///
    /// `UserDefaults.bool(forKey:)` cannot say "unset" — it answers `false` — so reading a
    /// default-on preference through it turns every existing install into one that has the
    /// feature switched off.
    private static func flag(_ key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
