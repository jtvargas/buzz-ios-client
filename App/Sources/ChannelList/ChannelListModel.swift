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
    /// Mention identities for each newest-message preview.
    private(set) var mentionsByMessageID: [String: MentionRefList] = [:]

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
                let rows = (try? store.channelList(selfPubkey: selfPubkey)) ?? []
                let messageIDs = rows.compactMap(\.lastMessageID)
                let mentions = (try? store.mentions(for: messageIDs)) ?? [:]
                await apply(rows, mentions: mentions)
            }
        } catch {
            // The stream ends on cancellation or store teardown; the last snapshot
            // remains on screen rather than blanking.
        }
    }

    func mentions(for channel: ChannelListRow) -> [MentionRef] {
        guard let messageID = channel.lastMessageID else { return [] }
        return mentionsByMessageID[messageID]?.refs ?? []
    }

    private func apply(_ rows: [ChannelListRow], mentions: [String: MentionRefList]) {
        channels = rows
        mentionsByMessageID = mentions
        hasLoaded = true
    }
}
