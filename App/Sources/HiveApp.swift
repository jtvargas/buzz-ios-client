import SwiftUI

@main
struct HiveApp: App {
    /// The composition root, created exactly once and owned by the app. `@State`
    /// (never `@StateObject`) is the iOS 17+ home for an `@Observable`.
    @State private var environment = AppEnvironmentBox()

    @Environment(\.scenePhase) private var scenePhase

    /// Lato reaches UIKit's own chrome from here, before the first window exists —
    /// an appearance proxy set after a bar is on screen leaves that bar on the old
    /// font. See ``HiveTypography/applyUIKitAppearance()``.
    init() {
        HiveTypography.applyUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            root
                // The app's typeface, inherited by every `Text` that does not name a font
                // of its own. Call sites that *do* name one say `.hive(_:)`; this is what
                // catches the rest, and the reason a plain `Text` in a list row is not the
                // only San Francisco left on the screen.
                //
                // On the window's whole content rather than on ``launch``, so the failure
                // screen and the UI-test fixture host are set in the same face as the app.
                // The fixture host is the surface `ConversationScrollTests` drives, and a
                // scroll assertion measured against San Francisco while the shipping app
                // draws Lato is a test measuring a screen nobody has.
                .environment(\.font, .hive(.body))
        }
        .onChange(of: scenePhase) { _, phase in
            environment.value?.handleScenePhase(phase)
        }
    }

    @ViewBuilder
    private var root: some View {
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
