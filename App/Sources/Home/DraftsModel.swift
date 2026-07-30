import BuzzKit
import Foundation
import Observation

/// Drives ``DraftsView``, and supplies the Drafts shortcut card's number: every composer
/// on this device that is holding unsent text, most recently edited first.
///
/// Owned by ``ChannelListView`` rather than by the screen, for the same reason the thread
/// read marks are: the sidebar draws the count and the pushed screen draws the list, and
/// they must be the same list. One observation serves both.
///
/// The read is live over `composer_draft` alone — see
/// ``DatabaseSignal/composerDrafts(in:)`` for why that table is deliberately outside the
/// signal every other list in the app shares.
@MainActor
@Observable
final class DraftsModel {
    /// The rows, newest edit first. Snippets, never whole drafts.
    private(set) var summaries: [ComposerDraftSummary] = []
    /// True once the first snapshot lands, so the screen can tell "no drafts" from
    /// "not read yet".
    private(set) var hasLoaded = false

    /// The shortcut card's number.
    ///
    /// Held separately from `summaries.count` and fed by its own de-duplicated
    /// observation: the card is on screen for the whole session, and the list is not.
    /// Reading the number this way means typing a word moves nothing on the sidebar unless
    /// it actually created or emptied a draft.
    private(set) var count = 0

    /// Rows this screen has deleted, against the version it deleted, until the store
    /// agrees they are gone.
    ///
    /// A delete is optimistic — the row leaves under the finger — but the list is *live*,
    /// and the write is queued through the composer cache's coalescing drain. Without
    /// this, the observation fires on the first of several deletes and re-reads a table
    /// that still holds the rest, putting rows the reader just removed back on screen
    /// until the writes land. The suite reproduced exactly that.
    ///
    /// Keyed to the version deleted, not merely to the id, so a conversation typed into
    /// again after its draft was thrown away comes *back*: the new row carries a newer
    /// `updatedAt` and stops being suppressed. Settling this by identity rather than by
    /// elapsed time is the same rule the reply tally is built on — there is no clock here
    /// that both sides share.
    private var discarded: [String: Int64] = [:]

    private let store: BuzzEventStore
    /// Where a delete goes. The cache is the authority inside a session, so a delete that
    /// only removed the row would be undone by the next visit — see
    /// ``ComposerDrafts/discard(_:)``. `nil` in tests that only read.
    private let drafts: ComposerDrafts?

    init(store: BuzzEventStore, drafts: ComposerDrafts?) {
        self.store = store
        self.drafts = drafts
    }

    /// Keeps ``count`` current. Attach with `.task` from the sidebar, which draws the card.
    nonisolated func runCount() async {
        do {
            for try await value in DatabaseSignal.draftCount(in: store.reader) {
                await MainActor.run { self.count = value }
            }
        } catch {
            // Ends on cancellation or teardown; the last count stays on the card.
        }
    }

    /// Keeps ``summaries`` current. Attach with `.task` from the screen, so a table written
    /// on every keystroke is only re-read while somebody is looking at the list.
    nonisolated func runList() async {
        do {
            for try await _ in DatabaseSignal.composerDrafts(in: store.reader) {
                let rows = (try? store.composerDraftSummaries()) ?? []
                await MainActor.run { self.apply(rows) }
            }
        } catch {
            // Ends on cancellation or teardown; the last snapshot stays on screen.
        }
    }

    /// Throws these drafts away. The list is updated here rather than waiting for the
    /// observation, so a row leaves under the finger that deleted it — see ``discarded``
    /// for what keeps it gone until the store agrees.
    ///
    /// ``count`` is deliberately not touched: it has one writer, the de-duplicated count
    /// observation, and it will move when the rows actually go.
    func delete(_ ids: Set<String>) {
        let removed = summaries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        for row in removed { discarded[row.id] = row.updatedAt }
        summaries.removeAll { ids.contains($0.id) }
        drafts?.discard(removed.map { ComposerDraftKey(channel: $0.channelID, root: $0.rootID) })
    }

    func deleteAll() {
        delete(Set(summaries.map(\.id)))
    }

    /// One snapshot, less anything this screen has deleted that the store has not caught
    /// up with yet.
    private func apply(_ rows: [ComposerDraftSummary]) {
        var stillPending: [String: Int64] = [:]
        var visible: [ComposerDraftSummary] = []
        for row in rows {
            if let deletedAt = discarded[row.id], row.updatedAt <= deletedAt {
                // The same version this screen deleted. Keep hiding it, and keep waiting.
                stillPending[row.id] = deletedAt
            } else {
                visible.append(row)
            }
        }
        discarded = stillPending
        summaries = visible
        hasLoaded = true
    }
}
