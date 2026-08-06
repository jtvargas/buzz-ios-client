import AppIntents

/// Opens one of the app's screens, chosen as a parameter.
///
/// The composable half of the pair. A person building a workflow in the Shortcuts app gets
/// **one** Hive action with a picker on it rather than a growing list of near-identical
/// tiles, and a fourth destination appears in that picker the moment it appears in
/// ``AppDestination`` — no new intent, no new registration.
///
/// The spoken half is ``OpenThreadsIntent`` and its siblings. Both exist deliberately:
/// a parameterised action is what *composes*, and a zero-parameter action is what a person
/// can *say* and what Spotlight can list as a single tap. They share one line of behaviour,
/// so there is no second implementation to keep in step.
struct OpenDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Screen"
    static let description = IntentDescription(
        "Opens one of Hive's screens: Threads, Later, or Drafts.",
        categoryName: "Navigation"
    )

    /// Navigation is the whole action, so there is nothing to do in the background — the
    /// app has to be in front of the person for this to have meant anything.
    static let openAppWhenRun = true

    @Parameter(title: "Screen")
    var destination: AppDestination

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$destination)")
    }

    /// Resolved by `AppDependencyManager`, registered in ``HiveApp/init()``.
    @Dependency
    private var navigator: AppNavigator

    @MainActor
    func perform() async throws -> some IntentResult {
        navigator.request(.destination(destination))
        return .result()
    }
}

/// Opens the Threads screen — recent thread activity across every channel.
///
/// The named, sayable form of ``OpenDestinationIntent`` with `.threads` filled in. It is a
/// separate type rather than a preconfigured parameter because that is what gives Siri a
/// phrase to match, Spotlight a single tile to show, and the Shortcuts gallery a row with
/// this screen's own name on it.
///
/// A second destination becomes an intent by copying these eight lines and changing the
/// word — see `PLANS/HIVE_APP_INTENTS_ARCHITECTURE.md`.
struct OpenThreadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Threads"
    static let description = IntentDescription(
        "Opens recent thread activity across every channel.",
        categoryName: "Navigation"
    )

    static let openAppWhenRun = true

    @Dependency
    private var navigator: AppNavigator

    @MainActor
    func perform() async throws -> some IntentResult {
        navigator.request(.destination(.threads))
        return .result()
    }
}

/// Opens messages saved for later.
///
/// The named, sayable form of ``OpenDestinationIntent`` with `.later` filled in.
struct OpenLaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Later"
    static let description = IntentDescription(
        "Opens messages saved to be reminded about.",
        categoryName: "Navigation"
    )

    static let openAppWhenRun = true

    @Dependency
    private var navigator: AppNavigator

    @MainActor
    func perform() async throws -> some IntentResult {
        navigator.request(.destination(.later))
        return .result()
    }
}

/// Opens conversations holding unsent text.
///
/// The named, sayable form of ``OpenDestinationIntent`` with `.drafts` filled in.
struct OpenDraftsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Drafts"
    static let description = IntentDescription(
        "Opens conversations holding unsent text.",
        categoryName: "Navigation"
    )

    static let openAppWhenRun = true

    @Dependency
    private var navigator: AppNavigator

    @MainActor
    func perform() async throws -> some IntentResult {
        navigator.request(.destination(.drafts))
        return .result()
    }
}
