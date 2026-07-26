import BuzzKit
import GRDB
import Observation

/// Keeps the app's identity directory live from the store.
///
/// One pattern, shared with ``ChannelListModel`` and ``ChannelTimelineModel``: a
/// `ValueObservation` over the store (``DatabaseSignal``) re-fires on every relevant
/// commit and each fire re-reads ``BuzzEventStore/directorySnapshot()``. Held once
/// near the root and composed with the live channel list into the ``EntityNames``
/// injected down the tree, so a profile landing renames that person on every
/// surface at once — sidebar, header, row, mention suggestion — with no per-row
/// query.
@MainActor
@Observable
final class EntityDirectoryModel {
    /// Identities and rosters as of the last commit; ``DirectorySnapshot/empty``
    /// until the first read lands.
    private(set) var snapshot: DirectorySnapshot = .empty

    private let store: BuzzEventStore

    init(store: BuzzEventStore) {
        self.store = store
    }

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`.
    /// `nonisolated` so the re-read runs on the concurrent reader off the main actor;
    /// only the assignment hops back on.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let snapshot = (try? store.directorySnapshot()) ?? .empty
                await apply(snapshot)
            }
        } catch {
            // The stream ends on cancellation or store teardown; the last snapshot
            // stays in force rather than un-naming everyone on screen.
        }
    }

    private func apply(_ snapshot: DirectorySnapshot) {
        // Assigning an equal snapshot would invalidate every view reading
        // `EntityNames` on any unrelated commit (a reaction, a read-state blob), so
        // the guard is what keeps the directory from being a global re-render pump.
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
    }
}
