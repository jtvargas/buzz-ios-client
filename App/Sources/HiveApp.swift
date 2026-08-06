import AppIntents
import SwiftUI

@main
struct HiveApp: App {
    /// The composition root, created exactly once and owned by the app. `@State`
    /// (never `@StateObject`) is the iOS 17+ home for an `@Observable`.
    @State private var environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase

    /// Inter reaches UIKit's own chrome from here, before the first window exists —
    /// an appearance proxy set after a bar is on screen leaves that bar on the old
    /// font. See ``HiveTypography/applyUIKitAppearance()``.
    init() {
        HiveTypography.applyUIKitAppearance()
        // Built here rather than in the property's initialiser so the one instance can be
        // handed to App Intents below — the intents are not part of the view tree, so this
        // is the only place both halves are in scope at once.
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        // Registered before any window exists, because an intent that *launches* the app
        // runs its `perform()` as soon as the process is up — earlier than `.task`, earlier
        // than the first `body`. An unregistered `@Dependency` traps when the intent reads
        // it, so this line is what stands between "Open Threads in Hive" and a crash on a
        // cold launch. See ``AppNavigator``.
        AppDependencyManager.shared.add(dependency: environment.navigator)
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
                // …and the ground that goes with it. One call puts the chosen theme into the
                // environment for `hiveScreenGround()`, onto `Color.hiveAccent` for the call
                // sites that draw the app's own colour, and onto the window for what UIKit
                // draws — the composer's caret and selection handles, menus, alerts.
                //
                // Reading `environment.settings.theme` here is what makes the change immediate:
                // `AppSettings` is `@Observable`, so writing the id in Settings re-evaluates
                // this scene and every screen under it.
                .hiveTheme(environment.settings.theme)
                // An invitation handed over by the system — the relay's own web page sends
                // `buzz://join?relay=…&code=…` once its terms have been accepted there
                // (`buzz/web/src/features/invite/ui/InvitePage.tsx:113`). Declared on the
                // whole window rather than inside ``launch``, so an invite tapped while the
                // app is at the identity gate is handled by the same door as one tapped
                // with a community open.
                .onOpenURL { url in _ = environment.handle(incomingURL: url) }
                // Hive is dark, on a light-mode phone as much as on a dark one.
                //
                // It was already dark everywhere it was drawn by hand — the conversation, the
                // sidebar, the honeycomb — and the screens that had not been gone over yet were
                // the ones that flipped: a `Form`, a `List`, a system alert. So light mode was
                // never a second design this app supported, it was the set of places the first
                // one had not reached, and it looked like a bug because it was one.
                //
                // Here rather than on ``launch``, so the DEBUG fixture host is set the same way
                // the shipping app is — a scroll test measured on a light background is a test
                // of a screen nobody has. The UIKit half, which this does not reach, is
                // `UIUserInterfaceStyle` in `Info.plist`.
                .preferredColorScheme(.dark)
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
        } else if InAppNotificationFixture.requested {
            InAppNotificationFixtureHost()
        } else if let picker = DirectMessagePickerFixture.requested {
            // The same idea for a sheet whose only input is a list of people, so its states
            // can be reviewed as pictures before the feature reaches a phone — see
            // ``DirectMessagePickerFixture``.
            DirectMessagePickerFixtureHost(state: picker)
        } else if let theme = SettingsFixture.requested() {
            // And for Settings, whose theme picker is a row of swatches that has already been
            // wrong in a way only a picture showed — see ``SettingsFixture``.
            SettingsFixtureHost(themeID: theme)
        } else if let avatarKit = AvatarKitEditorFixture.requested() {
            // And for the avatar builder, which is a grid of ninety-eight drawings and so is
            // entirely a thing to be looked at — see ``AvatarKitEditorFixture``.
            AvatarKitEditorFixtureHost(mode: avatarKit)
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
