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
///
/// Rosters are deliberately *not* read here. ``EntityDirectoryModel`` already reads
/// every channel's members in one `directorySnapshot()`, and the sidebar's presence
/// marker takes them from the resolver — so the sidebar derives a roster once per
/// commit, not twice.
@MainActor
@Observable
final class ChannelListModel {
    /// Channels, most-recently-active first, messageless last — the order
    /// `channelList()` already returns.
    private(set) var channels: [ChannelListRow] = []
    /// True once the first snapshot has been applied, so the view can tell "empty"
    /// from "not loaded yet".
    private(set) var hasLoaded = false
    /// How many threads hold replies the reader has not seen — the Threads shortcut's
    /// number. Threads, not replies: see ``BuzzEventStore/newThreadCount(selfPubkey:)``.
    private(set) var newThreadCount = 0

    private let store: BuzzEventStore
    /// The local identity, so a channel's own posts are excluded from its unread
    /// count. `nil` degrades to counting every author (keyless fallback).
    private let selfPubkey: String?

    init(store: BuzzEventStore, selfPubkey: String? = nil) {
        self.store = store
        self.selfPubkey = selfPubkey
    }

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`,
    /// which cancels it when the view goes away. `nonisolated` so the re-read runs
    /// off the main actor; only the property assignment hops back on.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                // One read. The second — a `mentions(for:)` batch over every row's newest
                // message id — went with the preview line it fed: the sidebar's mention
                // badge is now a column on this same query, counted over every unread
                // message rather than guessed from the newest one's `p` tags.
                let rows = (try? store.channelList(selfPubkey: selfPubkey)) ?? []
                // A count, not the thread list: the shortcut needs a number, and reading
                // fifty threads' worth of openers and replies per commit to draw one digit
                // is work the Threads screen does when it is actually open.
                let threads = (try? store.newThreadCount(selfPubkey: selfPubkey)) ?? 0
                await apply(rows, newThreadCount: threads)
            }
        } catch {
            // The stream ends on cancellation or store teardown; the last snapshot
            // remains on screen rather than blanking.
        }
    }

    private func apply(_ rows: [ChannelListRow], newThreadCount threads: Int) {
        // The same guard ``EntityDirectoryModel/apply(_:)`` carries, and for the same
        // reason: the observation re-fires on *every* committed transaction, so a
        // reaction, a typing-unrelated read-state blob, or a message in a channel whose
        // row did not change would otherwise assign an equal list — and an equal
        // assignment still invalidates every view reading it. This view is the sidebar
        // and the root of the environment the whole app resolves names through, so that
        // is a global re-render pump. Covers every assigned property, `hasLoaded`
        // included, so the very first (empty) snapshot still lands.
        guard rows != channels || threads != newThreadCount || !hasLoaded else { return }
        channels = rows
        newThreadCount = threads
        hasLoaded = true
    }
}
