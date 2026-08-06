import AppIntents

/// The actions the system offers without anybody setting them up: what Siri answers to,
/// what Spotlight lists under the app, and what the Shortcuts gallery shows in Hive's own
/// section.
///
/// # Two things here are load-bearing, and neither can be read back
///
/// `AppShortcut` publishes initialisers and **no properties**, so nothing below can be
/// asserted by loading this list in a test. Both rules are therefore kept by hand here, and
/// by the one pin that can be written from the other side.
///
/// **Every phrase must contain `\(.applicationName)`.** A phrase without the app-name token
/// is dropped at build time — no error, no warning, just a Siri command that does nothing.
/// There is no way to assert it: this is verified by saying it to Siri on a device, and it
/// is the reason that check is first in the device pass.
///
/// **`systemImageName` is a literal because the compiler requires one** — it is declared
/// `_const Swift.String` in the framework, so `HomeShortcut.threads.symbol`, which is where
/// that name really lives, is a compile error here rather than a silent drift. The pin runs
/// the other way instead: `AppDestinationTests` asserts the card still carries
/// `"text.append"`, so changing the card fails a test that names this file.
/// An SF Symbol the system does not have draws nothing at all, silently — the same trap
/// ``HomeShortcut/symbol(hasItems:)`` is already pinned against.
struct HiveShortcuts: AppShortcutsProvider {
    /// Hive's honey amber has no exact system tile colour; orange is the nearest warm,
    /// saturated option without pushing the tile toward yellow or red.
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenThreadsIntent(),
            phrases: [
                "Open Threads in \(.applicationName)",
                "Show my threads in \(.applicationName)",
                "Open my \(.applicationName) threads",
            ],
            shortTitle: "Threads",
            systemImageName: "text.append"
        )

        AppShortcut(
            intent: OpenLaterIntent(),
            phrases: [
                "Open Later in \(.applicationName)",
                "Show Later in \(.applicationName)",
                "Show my saved messages in \(.applicationName)",
            ],
            shortTitle: "Later",
            systemImageName: "bookmark"
        )

        AppShortcut(
            intent: OpenDraftsIntent(),
            phrases: [
                "Open Drafts in \(.applicationName)",
                "Show my drafts in \(.applicationName)",
                "Open my \(.applicationName) drafts",
            ],
            shortTitle: "Drafts",
            systemImageName: "paperplane"
        )

        // The one parameterised entry. Its phrases are what
        // ``updateAppShortcutParameters()`` regenerates: without a shortcut naming
        // ``OpenConversationIntent``, that call has nothing to refresh and no spoken
        // channel name can match anything, however well the entity is indexed.
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: [
                "Open \(\.$conversation) in \(.applicationName)",
                "Open the \(\.$conversation) channel in \(.applicationName)",
                "Show \(\.$conversation) in \(.applicationName)",
            ],
            shortTitle: "Open Conversation",
            systemImageName: "number"
        )
    }
}
