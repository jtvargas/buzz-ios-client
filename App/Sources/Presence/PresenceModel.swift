import BuzzKit
import Observation

/// The workspace presence roster, live from ``PresenceStore``.
///
/// Presence is workspace-global (S-5): a peer is "online" wherever they last
/// published a heartbeat, not per channel. This model holds the set of online
/// pubkeys so any surface — a timeline author dot, a member list — can ask whether a
/// key is present without each maintaining its own subscription's worth of state.
@MainActor
@Observable
final class PresenceModel {
    /// The pubkeys currently present in the workspace.
    private(set) var online: Set<String> = []

    private let store: PresenceStore

    init(store: PresenceStore) {
        self.store = store
    }

    /// Whether a given author is currently present.
    func isOnline(_ pubkey: String) -> Bool {
        online.contains(pubkey)
    }

    /// Consumes the roster stream until cancelled. Attach with SwiftUI's `.task`.
    func run() async {
        for await roster in await store.workspacePresence() {
            online = Set(roster.map(\.pubkey))
        }
    }
}
