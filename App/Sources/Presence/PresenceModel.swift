import BuzzKit
import Observation

/// The workspace presence roster, live from ``PresenceStore``.
///
/// Presence is workspace-global (S-5): a peer is "online" wherever they last
/// published a heartbeat, not per channel. This model holds each present peer's
/// announced status so any surface — a timeline author dot, a member list — can ask
/// about a key without each maintaining its own subscription's worth of state.
///
/// A status rather than a bare set because `away` and `online` are different facts
/// about a person and the relay has always carried both; collapsing them here was
/// what made an idle peer indistinguishable from one at the keyboard. Absence from
/// the map is the third state: not present.
@MainActor
@Observable
final class PresenceModel {
    /// Each present peer's announced status, keyed by pubkey.
    private(set) var statuses: [String: PresenceStatus] = [:]

    private let store: PresenceStore

    init(store: PresenceStore) {
        self.store = store
    }

    /// A given peer's status, or `nil` when they are not present.
    func status(of pubkey: String) -> PresenceStatus? {
        statuses[pubkey]
    }

    /// Whether a given author is currently present, in any status.
    func isOnline(_ pubkey: String) -> Bool {
        statuses[pubkey] != nil
    }

    /// Consumes the roster stream until cancelled. Attach with SwiftUI's `.task`.
    func run() async {
        for await roster in await store.workspacePresence() {
            statuses = Dictionary(
                roster.map { ($0.pubkey, $0.status) },
                uniquingKeysWith: { _, newest in newest }
            )
        }
    }
}
