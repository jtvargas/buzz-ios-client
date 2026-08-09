import SwiftUI
import WidgetKit

/// The Threads count on the Home Screen, drawn as the shortcut card it mirrors.
///
/// `StaticConfiguration` and not an intent-configured one: this covers the community the
/// app has open, because that is the only one the app can compute a snapshot for today
/// (§ ``ThreadsWidgetSnapshotWriter``). A community picker is the next step and needs the
/// app to walk every community's store, not a change here.
@main
struct ThreadsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ThreadsWidget()
    }
}

struct ThreadsWidget: Widget {
    static let kind = "ThreadsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ThreadsTimelineProvider()) { entry in
            ThreadsWidgetView(entry: entry)
                // The app's ground, so a widget beside the app icon reads as the same
                // surface. `hiveNight` — the literal is repeated rather than shared because
                // reaching `App/Sources/Support/HoneycombBackground.swift` from an extension
                // would drag the app's whole colour stack across the target boundary for one
                // colour.
                .containerBackground(Self.ground, for: .widget)
        }
        .configurationDisplayName("Threads")
        .description("New replies in threads you're part of.")
        .supportedFamilies([.systemSmall])
    }

    static let ground = Color(red: 0.021, green: 0.025, blue: 0.029)
}

/// One rendered moment: what to draw, and how much to trust it.
struct ThreadsEntry: TimelineEntry {
    let date: Date
    let state: State

    enum State: Equatable {
        /// No snapshot in the App Group — the app has never run since the widget was added,
        /// or the reader is signed out. Drawn as an invitation, never as a zero: a zero the
        /// reader cannot tell from a real zero is the worst thing this widget could show.
        case needsApp
        /// A number, and what it is worth.
        case counted(Counted)
    }

    struct Counted: Equatable {
        let count: Int
        let communityName: String
        /// When the number was established — a successful fetch, or the app's own last
        /// write when the fetch failed.
        let asOf: Date
        /// Whether this is the app's remembered number rather than one just fetched.
        let isStale: Bool
        /// Whether the relay filled its page, making `count` a floor.
        let isFloor: Bool
    }
}
