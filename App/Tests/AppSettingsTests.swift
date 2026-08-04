import Foundation
@testable import Hive
import Testing

/// The app-wide preferences, and the one thing about them that is easy to get silently wrong.
///
/// `UserDefaults.bool(forKey:)` answers `false` for a key nobody has written, so a preference
/// that is meant to start *on* reads as off on every install that predates it. For notifications
/// that failure is invisible in exactly the wrong way: alerts simply stop arriving, the switch
/// on the settings screen agrees that they should not, and nothing anywhere says a default was
/// misread. Hence the first test.
@Suite("App settings")
@MainActor
struct AppSettingsTests {
    /// A throwaway defaults suite, so a test run never writes over the preferences of whatever
    /// build is installed on the machine.
    private func makeSuite() -> (defaults: UserDefaults, name: String) {
        let name = "hive.tests.settings.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func forget(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test("notifications are on for an install that has never seen this screen")
    func notificationsDefaultToOn() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        #expect(defaults.object(forKey: AppSettings.Key.notificationsEnabled) == nil)
        #expect(AppSettings(defaults: defaults).notificationsEnabled)
    }

    @Test("the switch survives a relaunch, in both positions")
    func theSwitchRoundTrips() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        let settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = false
        // A fresh object over the same defaults is what a relaunch is. Off has to survive it
        // for the same reason on does — and it is the direction the default would mask.
        #expect(AppSettings(defaults: defaults).notificationsEnabled == false)

        settings.notificationsEnabled = true
        #expect(AppSettings(defaults: defaults).notificationsEnabled)
    }

    @Test("two objects over the same defaults do not disagree after a write")
    func aWriteIsVisibleToTheNextReader() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        AppSettings(defaults: defaults).notificationsEnabled = false
        #expect(defaults.bool(forKey: AppSettings.Key.notificationsEnabled) == false)
    }

    @Test("the storage key is the one already on people's phones")
    func theStorageKeyIsPinned() {
        // Renaming this resets the preference for every existing install, and — unlike a
        // renamed symbol — nothing in the compiler notices.
        #expect(AppSettings.Key.notificationsEnabled == "settings.notifications.enabled")
        #expect(AppSettings.Key.themeID == "settings.theme.id")
    }

    // MARK: - Theme

    @Test("an install that has never opened the picker is on Hive")
    func themeDefaultsToHive() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        #expect(defaults.object(forKey: AppSettings.Key.themeID) == nil)
        #expect(AppSettings(defaults: defaults).theme == .hive)
    }

    @Test("the chosen theme survives a relaunch")
    func theThemeRoundTrips() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        AppSettings(defaults: defaults).themeID = "nord"
        // A fresh object over the same defaults is what a relaunch is.
        #expect(AppSettings(defaults: defaults).theme.id == "nord")
    }

    @Test("an id nothing answers to falls back rather than leaving the app with no ground")
    func anUnknownThemeFallsBack() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        // An id written by a later version, or by a hand-edited defaults file. The app has to
        // draw *something*, and the something is the default.
        defaults.set("a-theme-from-the-future", forKey: AppSettings.Key.themeID)
        #expect(AppSettings(defaults: defaults).theme == .hive)
    }

    @Test("every theme has its own id")
    func themeIDsAreUnique() {
        // `named(_:)` takes the first match, so a duplicate id would make one theme
        // unreachable — and the picker would draw two swatches that select the same one.
        let ids = HiveTheme.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Hive is the first swatch, so the default is where somebody scrolls back to")
    func hiveLeadsThePicker() {
        #expect(HiveTheme.all.first == .hive)
    }
}
