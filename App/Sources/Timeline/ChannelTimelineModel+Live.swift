import BuzzKit
import Foundation

/// The channel timeline's live read side: the observation loop, and the page read it
/// and the paging both go through.
///
/// Its own file so ``ChannelTimelineModel`` keeps the state and the mutations that act
/// on it — ``ChannelTimelineModel/mergeHead(_:refreshing:)`` and the prune behind it stay
/// there, beside the `loaded` set they are the only writers of.
extension ChannelTimelineModel {
    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`.
    nonisolated func run() async {
        // Typing is delivered by the engine's standing per-channel content subscription
        // now, whose lifecycle discovery and membership own — the view no longer opens
        // or closes it. This loop is purely the read side: observe, merge, mark read.
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let head = fetch(before: nil)
                // The head is the newest page and speaks only for itself, but the loaded
                // set can reach further back than it — every row an older page brought in,
                // and every row that has since drifted past the newest page. Those rows
                // still change: a reply landing on one moves its `reply_count` and
                // `last_reply_at`, and without this the row kept the tally it was fetched
                // with and its replies CTA never appeared for the life of the screen.
                // Re-read exactly those, by id, through the timeline's own row query.
                let refreshed = await fetchRefreshed(outsideHead: head)
                // Merging rebuilds the rendered set, which is also what marks the
                // channel read up to the newest row the reader can actually see.
                let ids = await mergeHead(head, refreshing: refreshed)
                // Same signal, same reader, off the main actor: re-read reactions and
                // mentions for every loaded row so chips and @-tokens track the
                // timeline exactly.
                let groups = fetchReactions(for: ids)
                await applyReactions(groups)
                let mentions = fetchMentions(for: ids)
                await applyMentions(mentions)
                // Only the threaded rows, and only after the merge that decided which
                // rows those are — a reply landing is exactly the commit that turns a
                // plain row into a threaded one.
                let roots = await threadedRowIDs
                let participants = fetchThreadParticipants(for: roots)
                await applyThreadParticipants(participants)
            }
        } catch {
            // Ends on cancellation or teardown; last snapshot stays on screen.
        }
    }

    /// Reads one page off the main actor. `channel`, `store`, and `pageSize` are
    /// immutable, so this is safe to call from the `nonisolated` observation loop.
    nonisolated func fetch(before cursor: TimelineCursor?) -> [TimelineRow] {
        (try? store.timeline(channel: channel, before: cursor, limit: pageSize)) ?? []
    }
}
