import BuzzKit
import GRDB
import Observation

/// Drives ``ChannelListView`` from a live observation of the store.
///
/// One pattern, shared with ``ChannelTimelineModel``: a `ValueObservation` over
/// the `event`/`outbox` region (``DatabaseSignal``) re-fires on every relevant
/// commit, and each fire re-reads `store.channelList()` — BuzzKit's public,
/// deletion-aware, outbox-unioned query. SwiftUI reads plain properties; the model
/// never keeps a second list to fall out of step.
@MainActor
@Observable
final class ChannelListModel {
    /// Channels, most-recently-active first, messageless last — the order
    /// `channelList()` already returns.
    private(set) var channels: [ChannelListRow] = []
    /// True once the first snapshot has been applied, so the view can tell "empty"
    /// from "not loaded yet".
    private(set) var hasLoaded = false

    private let store: BuzzEventStore

    init(store: BuzzEventStore) {
        self.store = store
    }

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`,
    /// which cancels it when the view goes away. `nonisolated` so the re-read runs
    /// off the main actor; only the property assignment hops back on.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let rows = (try? store.channelList()) ?? []
                await apply(rows)
            }
        } catch {
            // The stream ends on cancellation or store teardown; the last snapshot
            // remains on screen rather than blanking.
        }
    }

    private func apply(_ rows: [ChannelListRow]) {
        channels = rows
        hasLoaded = true
    }
}
