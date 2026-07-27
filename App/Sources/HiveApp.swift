import SwiftUI

@main
struct HiveApp: App {
    /// The composition root, created exactly once and owned by the app. `@State`
    /// (never `@StateObject`) is the iOS 17+ home for an `@Observable`.
    @State private var environment = AppEnvironmentBox()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // A launch argument opens the real conversation surface on a seeded throwaway
            // store, so the scroll shapes can be driven from a UI test without a relay. Off
            // unless asked for, and compiled out of release entirely — see
            // ``ConversationFixture``.
            if let fixture = ConversationFixture.requested {
                ConversationFixtureHost(options: fixture)
            } else {
                launch
            }
            #else
            launch
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            environment.value?.handleScenePhase(phase)
        }
    }

    /// The normal launch: the composition root, or the one failure a user cannot resolve.
    @ViewBuilder
    private var launch: some View {
        if let environment = environment.value {
            RootView()
                .environment(environment)
                .task { await environment.bootstrap() }
        } else {
            LaunchFailureView(message: environment.failure ?? "The app could not start.")
        }
    }
}

/// Wraps the throwing construction of ``AppEnvironment`` so the `@State` initialiser
/// stays non-failing. Opening the store can throw (a corrupt or unwritable app
/// container); that is surfaced in-app rather than crashing at launch.
@MainActor
private struct AppEnvironmentBox {
    let value: AppEnvironment?
    let failure: String?

    init() {
        do {
            value = try AppEnvironment()
            failure = nil
        } catch {
            value = nil
            failure = String(describing: error)
        }
    }
}

/// The last-resort launch screen: shown only when the store itself could not be
/// opened, which no user action inside the app can fix.
private struct LaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Hive couldn't start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}
