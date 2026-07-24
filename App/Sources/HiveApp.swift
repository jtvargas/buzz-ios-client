import SwiftUI

@main
struct HiveApp: App {
    /// The composition root, created exactly once and owned by the app. `@State`
    /// (never `@StateObject`) is the iOS 17+ home for an `@Observable`.
    @State private var environment = AppEnvironmentBox()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let environment = environment.value {
                RootView()
                    .environment(environment)
                    .task { await environment.bootstrap() }
            } else {
                LaunchFailureView(message: environment.failure ?? "The app could not start.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.value?.handleScenePhase(phase)
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
