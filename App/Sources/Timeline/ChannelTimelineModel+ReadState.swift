import BuzzKit
import Foundation

// MARK: - Read state

/// Mark-on-view: how far the reader has demonstrably seen, and when that is published.
///
/// Its own file, beside the model rather than in it, because it is the one concern here
/// that leaves the device — the NIP-RS frontier is shared with every other client the
/// account is signed in to, and grow-only.
extension ChannelTimelineModel {
    /// Marks the channel read up to the newest *rendered* message, once per advance —
    /// mark-on-view. Fires the moment the channel opens and again whenever a newer
    /// message becomes viewable while the view is up; a scroll back through older
    /// history leaves the newest rendered row unchanged, so it re-marks nothing.
    ///
    /// The newest *rendered* row, not the newest loaded one. While the tail is frozen
    /// the reader can see nothing past the boundary, and the NIP-RS frontier is
    /// grow-only and shared with every other device — so advancing it past held-back
    /// arrivals is not recoverable: the pill said "3 new messages" while the sidebar row
    /// for the same channel dropped to zero unread and un-bolded, and backing out lost
    /// the marker everywhere.
    ///
    /// Called from ``ChannelTimelineModel/rebuild()``, so it tracks the rendered set for
    /// any reason it advances — an arrival, the channel opening, an older page, or the
    /// freeze releasing — and the `lastMarkedReadAt` guard makes every redundant call free.
    ///
    /// Fire-and-forget so the observation loop never blocks on the publish, and
    /// grow-only on the engine side so a redundant call is a no-op.
    func markReadIfNeeded() {
        guard let readStateMarking,
              let newest = rows.last?.createdAt, newest > lastMarkedReadAt else { return }
        lastMarkedReadAt = newest
        let channel = self.channel
        Task { await readStateMarking.markRead(channel: channel, upTo: newest) }
    }
}
