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

    /// Bumped once per *accepted* snapshot, so a view can hang a derivation off this
    /// rather than off ``snapshot`` itself.
    ///
    /// The distinction is the whole point. A `DirectorySnapshot` is two dictionaries
    /// covering every identity and every roster in the community, so `onChange(of:)`
    /// against it pays a whole-directory comparison to learn what one integer compare
    /// answers here. The guard in ``apply(_:)`` is what makes the counter trustworthy:
    /// the snapshot is assigned only when it genuinely differs, so a bump means new
    /// identities and a steady value means there is nothing to redo.
    private(set) var revision = 0

    private let store: BuzzEventStore
    /// The reader, who is in the snapshot whether or not a roster names them — which is
    /// what lets the toolbar draw their own face on a first join (§ ``BuzzKit/DirectorySnapshot``).
    /// No default: a caller that forgot it would silently get the `?` this argument exists
    /// to end.
    private let selfPubkey: String?

    init(store: BuzzEventStore, selfPubkey: String?) {
        self.store = store
        self.selfPubkey = selfPubkey
    }

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`.
    /// `nonisolated` so the re-read runs on the concurrent reader off the main actor;
    /// only the assignment hops back on.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let snapshot = (try? store.directorySnapshot(selfPubkey: selfPubkey)) ?? .empty
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
        revision &+= 1
    }
}
