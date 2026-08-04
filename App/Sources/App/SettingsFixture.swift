#if DEBUG
import SwiftUI

/// The Settings sheet, opened straight from a launch argument, so the theme picker can be
/// *looked at* on a simulator instead of only on a phone.
///
/// # Why this exists
///
/// The picker is fifteen swatches inside a card inside a sheet, and its first version shipped
/// as a horizontal row that drew past the card and off the right edge of the display. That is a
/// defect a picture catches in a second and a description never states at all — but Settings is
/// reached through the sidebar, and ``ChannelListView`` takes a concrete `SyncEngine`, so
/// getting to it on a simulator otherwise means standing up a socket.
///
/// ``SettingsView`` is the opposite shape: it reads ``AppEnvironment`` and nothing else, and
/// the one thing it does with the store is guarded by a `guard let`. So the surface under the
/// screenshot here is the shipping view, unmodified, presented the way the app presents it —
/// as a sheet, which is what gives the card its real width and its elevated ground.
///
/// `-fixtureSettings nord` opens it with Nord already chosen; the id is any
/// ``HiveTheme/id``, and an unknown one falls back the way the app does.
///
/// Compiled out of release entirely, like the two fixtures beside it.
enum SettingsFixture {
    /// The theme a launch asked to open on, or `nil` for an ordinary launch.
    ///
    /// The bare flag is allowed and means the default theme — `-fixtureSettings` on its own is
    /// the resting state, which is the one worth looking at most often.
    static func requested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let flag = arguments.firstIndex(of: "-fixtureSettings") else { return nil }
        let next = flag + 1
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("-") else {
            return HiveTheme.hive.id
        }
        return arguments[next]
    }
}

/// Presents ``SettingsView`` as the app presents it.
///
/// The theme is put into force on the host — not just written into settings — so the swatch
/// ring, the accent behind the sheet and the ground all show the chosen theme, which is the
/// whole point of looking at this screen.
struct SettingsFixtureHost: View {
    let themeID: String

    @State private var environment = AppEnvironment()

    var body: some View {
        Color.hiveNight
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                SettingsView()
                    .environment(environment)
            }
            .hiveTheme(.named(themeID))
            .onAppear { environment.settings.themeID = themeID }
    }
}
#endif
