import SwiftUI

@main
struct HiveApp: App {
    /// The composition root, created exactly once and owned by the app. `@State`
    /// (never `@StateObject`) is the iOS 17+ home for an `@Observable`.
    @State private var environment = AppEnvironment()

    @Environment(\.scenePhase) private var scenePhase

    /// Inter reaches UIKit's own chrome from here, before the first window exists —
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
                // draws Inter is a test measuring a screen nobody has.
                .environment(\.font, .hive(.body))
                // The accent, put into the environment explicitly rather than left to the
                // catalogue's global — which does not reach either framework on iOS, see
                // ``HiveAccent``. Every SwiftUI control that has not been tinted by hand —
                // a `Button`'s label, a `Link`, a `Toggle`, the swipe actions, the caret
                // SwiftUI hands to its own text fields — reads it from here.
                .tint(.hiveAccent)
                // And the same colour on the window underneath, for what UIKit draws:
                // the composer's caret and selection handles, menus, alerts.
                .hiveWindowTint()
                // An invitation handed over by the system — the relay's own web page sends
                // `buzz://join?relay=…&code=…` once its terms have been accepted there
                // (`buzz/web/src/features/invite/ui/InvitePage.tsx:113`). Declared on the
                // whole window rather than inside ``launch``, so an invite tapped while the
                // app is at the identity gate is handled by the same door as one tapped
                // with a community open.
                .onOpenURL { url in _ = environment.handle(incomingURL: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.handleScenePhase(phase)
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

    /// The normal launch: the composition root.
    ///
    /// Building it no longer opens anything that can fail. It used to open the one database
    /// this app had, which is why it was wrapped in a box that could hold a failure
    /// instead; with a database per community (§ ``Community``) the question "which one"
    /// belongs to the active community, so the open moved into the session start and its
    /// failure is drawn by ``RootView`` as ``AppEnvironment/Phase/failed(_:)`` — the same
    /// screen, one step later, and reachable for a switch as well as a launch.
    private var launch: some View {
        RootView()
            .environment(environment)
            .task { await environment.bootstrap() }
    }
}
