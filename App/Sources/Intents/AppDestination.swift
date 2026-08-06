import AppIntents

/// A screen the system can ask the app to open.
///
/// This is the app's routing vocabulary for everything that arrives from *outside* the view
/// tree — Siri, Spotlight, the Shortcuts app — and it is deliberately the only such
/// vocabulary. An intent names a destination; it does not know which stack that destination
/// lives in, which tab holds it, or what has to be popped to get there. Those are
/// ``ChannelListView``'s business, and keeping them there is what stops a second intent from
/// having to learn the navigation over again.
///
/// An `AppEnum` rather than a private enum, because that costs two properties and buys the
/// Shortcuts app a real parameter: ``OpenDestinationIntent`` takes one of these, so a person
/// assembling a workflow gets a picker with these three names in it rather than three
/// separate opaque actions. It is also the shape the `.messages` schema domain expects if
/// Hive later adopts one — see `PLANS/HIVE_APP_INTENTS_ARCHITECTURE.md`.
///
/// One case per destination, and ``HomeShortcut`` is pinned to it in `AppDestinationTests`:
/// a fourth shortcut card added without a destination fails that test rather than quietly
/// shipping a card Siri cannot reach.
enum AppDestination: String, AppEnum, CaseIterable {
    /// Recent thread activity across every channel. See ``ThreadsView``.
    case threads
    /// Messages saved to be reminded about. See ``LaterView``.
    case later
    /// Conversations holding unsent text. See ``DraftsView``.
    case drafts

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Screen")
    }

    /// What each destination is called wherever the system lists it — the Shortcuts
    /// parameter picker, and Siri reading a workflow back. The same words the cards carry,
    /// via ``HomeShortcut/title``, so the two cannot drift apart.
    static var caseDisplayRepresentations: [AppDestination: DisplayRepresentation] {
        [
            .threads: DisplayRepresentation(title: "Threads"),
            .later: DisplayRepresentation(title: "Later"),
            .drafts: DisplayRepresentation(title: "Drafts"),
        ]
    }
}

extension AppDestination {
    /// The shortcut card that opens this destination by hand.
    ///
    /// The mapping exists in both directions so the two lists are provably the same length
    /// and the same set — see `AppDestinationTests`. A card without a destination is a
    /// screen a person can reach with a finger and not with their voice, which is the exact
    /// asymmetry this pinning is here to catch.
    var shortcut: HomeShortcut {
        switch self {
        case .threads: .threads
        case .later: .later
        case .drafts: .drafts
        }
    }

    init(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .threads: self = .threads
        case .later: self = .later
        case .drafts: self = .drafts
        }
    }
}
