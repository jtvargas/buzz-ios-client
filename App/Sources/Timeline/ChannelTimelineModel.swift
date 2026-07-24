import BuzzKit
import Foundation
import GRDB
import NostrCore
import Observation

/// Drives ``ChannelTimelineView`` for one channel: a live head observation, keyset
/// pagination of older history, and the send / retry calls.
///
/// Rows are held ascending (oldest first) so the view can anchor to the bottom and
/// render newest-last. The live observation re-reads the newest page on every
/// relevant commit; older pages are loaded on demand and merged by id, so an edit,
/// a deletion, or a `pending → sent` transition updates the *same* row in place
/// rather than appearing twice.
@MainActor
@Observable
final class ChannelTimelineModel {
    let channel: String

    /// The loaded messages, ascending by `(createdAt, id)` — the total order the
    /// keyset query pages on, so "newest" means the same thing here and in the DB.
    private(set) var rows: [TimelineRow] = []
    private(set) var hasLoaded = false
    /// Whether an older page may still exist before the oldest loaded row.
    private(set) var hasMoreOlder = true
    private(set) var isLoadingOlder = false

    /// The composer's text. Bound by the view; cleared optimistically on send.
    var draft: String = ""
    /// Set when a send is refused before it leaves the device (over the 64 KiB
    /// ceiling); the view shows it and the draft text is preserved.
    var sendError: String?

    /// The `before` cursor most recently handed to `store.timeline(before:)`. A
    /// test seam: it is exactly the keyset position paged from, proving pagination
    /// never falls back to offset paging (spec §Step 1 tests).
    private(set) var lastOlderCursor: TimelineCursor?

    private let store: BuzzEventStore
    private let sender: any MessageSending
    private let pageSize: Int

    /// Loaded rows keyed by id, so a re-read of the head merges into — rather than
    /// duplicates — rows an older page already holds.
    private var loaded: [String: TimelineRow] = [:]
    /// The oldest loaded row's cursor, the basis of the next older page.
    private var earliest: TimelineCursor?

    init(
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        pageSize: Int = 50
    ) {
        self.channel = channel
        self.store = store
        self.sender = sender
        self.pageSize = pageSize
    }

    // MARK: - Live observation

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let head = fetch(before: nil)
                await mergeHead(head)
            }
        } catch {
            // Ends on cancellation or teardown; last snapshot stays on screen.
        }
    }

    /// Reads one page off the main actor. `channel`, `store`, and `pageSize` are
    /// immutable, so this is safe to call from the `nonisolated` observation loop.
    private nonisolated func fetch(before cursor: TimelineCursor?) -> [TimelineRow] {
        (try? store.timeline(channel: channel, before: cursor, limit: pageSize)) ?? []
    }

    private func mergeHead(_ head: [TimelineRow]) {
        let firstSnapshot = !hasLoaded
        for row in head { loaded[row.id] = row }
        rebuild()
        hasLoaded = true
        // The head is the newest page; a full page means older history may exist.
        // Decided only on the first snapshot — later head re-reads are new messages
        // at the top, which never re-open the tail.
        if firstSnapshot {
            hasMoreOlder = head.count >= pageSize
        }
    }

    // MARK: - Pagination

    /// Loads the page immediately older than the oldest loaded row, via the
    /// `(createdAt, id)` keyset cursor — never an offset. Idempotent while a load
    /// is in flight and once history is exhausted.
    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, let cursor = earliest else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        lastOlderCursor = cursor
        let older = fetch(before: cursor)
        for row in older { loaded[row.id] = row }
        rebuild()
        if older.count < pageSize { hasMoreOlder = false }
    }

    private func rebuild() {
        rows = loaded.values.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
        }
        earliest = rows.first.map(TimelineCursor.init(row:))
    }

    // MARK: - Send / retry

    /// Sends the composer draft. Optimistic and fire-and-forget: the draft is
    /// cleared and the pending row appears through the observation the moment the
    /// outbox row commits, long before the relay's OK. An over-ceiling message
    /// throws before it is queued — the text is restored and surfaced.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sendError = nil

        let channel = self.channel
        let sender = self.sender
        Task { [weak self] in
            do {
                try await sender.enqueue(
                    kind: .channelMessage,
                    content: text,
                    in: channel,
                    tags: [["h", channel]],
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
            } catch let error as OutboxError {
                await self?.restore(draft: text, error: error)
            } catch {
                // A transient send failure leaves the row queued in the outbox for
                // the next drain; nothing to surface and nothing to restore.
            }
        }
    }

    /// Returns a failed send to the queue and redrains — the "tap to retry" action.
    func retry(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.retry(eventID) }
    }

    private func restore(draft text: String, error: OutboxError) {
        // Preserve whatever the user has since typed, only restoring if untouched.
        if draft.isEmpty { draft = text }
        sendError = Self.describe(error)
    }

    private static func describe(_ error: OutboxError) -> String {
        switch error {
        case let .contentTooLarge(bytes, limit):
            "Message is too large (\(bytes) bytes; limit \(limit))."
        case .invalidEvent, .notQueued, .encodingFailed:
            "Couldn't send that message."
        }
    }
}
