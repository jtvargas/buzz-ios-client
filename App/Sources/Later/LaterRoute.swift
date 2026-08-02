import Foundation

/// The push onto the Later screen.
///
/// A type rather than a `Bool`, matching ``ThreadsRoute`` and ``DraftsRoute``: every push
/// this stack owns is programmatic and identified by a route, and
/// `navigationDestination(item:)` needs something `Hashable` to key on.
struct LaterRoute: Hashable, Identifiable {
    let id = UUID()
}
