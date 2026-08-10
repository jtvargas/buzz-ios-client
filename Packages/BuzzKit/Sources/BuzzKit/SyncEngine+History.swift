import Foundation
import NostrCore

/// On-demand scrollback: the page a reader asks for by scrolling past the oldest
/// row this device holds.
///
/// # Why this is not `reconcile`
///
/// ``SyncEngine/reconcile(_:generation:)`` pages a channel from its head down to the
/// watermark to close the offline gap, on a schedule the reader has no say in. It is
/// the wrong instrument for "show me what is above this row": it starts at the head,
/// it is driven by the socket rather than the scroll, and it runs every known channel
/// serially, so the channel on screen waits its turn in channel-id order.
///
/// This path is the other half — a single page, for one channel, at a position the
/// reader has scrolled to, awaited by the surface that asked. Buzz Desktop's
/// scrollback is the same request against the same relay (`get_channel_window` →
/// `POST /query` with `top_level`), and this exists because iOS had no equivalent at
/// all: paging older re-read local SQLite and nothing on that path could ever reach
/// the relay, so a reader hit the floor of whatever the background reconcile had
/// happened to finish and stopped there.
public extension SyncEngine {
    /// What one older page settled.
    struct OlderHistoryPage: Sendable, Equatable {
        /// Whether the relay holds anything older than the page just ingested.
        ///
        /// The relay's own `kind:39006` exhaustion fact, never a row count: a short
        /// page proves nothing (NIP-CW §Client Behavior), and an exact-multiple final
        /// page would read as "more" forever.
        public let hasMore: Bool

        /// Rows the page actually added to the log — duplicates excluded.
        ///
        /// A page can legitimately be all duplicates: the seed re-asks for the boundary
        /// second, and a channel whose reconcile already reached deeper answers the
        /// first few pages entirely from rows this device holds. The caller uses it to
        /// tell "nothing new *here*" from "nothing new anywhere", which are the same
        /// thing to a local read and are not the same thing at all.
        public let ingested: Int

        /// Public so a fixture can stand in for the relay. The scroll shapes this surface is
        /// measured by turn on a page landing *while the reader is moving*, and nothing in the
        /// app can produce that without a pager — which is why the defect it exists to catch
        /// was reported from a phone rather than caught here.
        public init(hasMore: Bool, ingested: Int) {
            self.hasMore = hasMore
            self.ingested = ingested
        }
    }

    /// Why an older page could not be fetched.
    ///
    /// Distinct from an empty result on purpose. Folding a failure into "history is
    /// exhausted" is what let a single unlucky read end scrollback permanently with no
    /// error and nothing to retry — the caller has to be able to keep the door open.
    enum OlderHistoryError: Error, Sendable, Equatable {
        /// The engine is stopped, or its socket is not up. Retriable once it is.
        case notRunning
        /// The window fast path is unavailable on this relay for this session, so
        /// there is no cursored request to page with. Retriable on the next `.ready`,
        /// which re-arms ``SyncEngine/windowDegraded``.
        case unavailable
        /// The relay served a page that failed a bounds-integrity MUST. The fast path
        /// survives it (NIP-CW §Client Behavior step 5) and the same request MAY be
        /// retried.
        case invalidPage
        /// The page arrived intact but the write did not land — a busy database against a
        /// concurrent reconcile, or a projector that threw. Retriable, and the cursor has
        /// not moved, so the retry asks for this same page again.
        case notIngested
    }

    /// Fetches the channel-window page immediately older than the reader's floor,
    /// ingests it, and reports whether the relay holds anything older still.
    ///
    /// - Parameters:
    ///   - channel: the channel being read.
    ///   - floor: the oldest row the caller currently holds. Used only to *seed* this
    ///     channel's cursor chain, and only for the first page — see `cursor(for:below:)`
    ///     for why consulting it again is worse than it looks.
    ///
    /// # The cursor
    ///
    /// After the first page, the cursor is always one the relay minted
    /// (``WindowBounds/nextCursor``), which is the only kind that describes a position
    /// in the relay's `(created_at DESC, id ASC)` order exactly. That matters here and
    /// not in ``SyncEngine/reconcile(_:generation:)``, which only ever echoes relay
    /// cursors: this device's local timeline orders ties the other way (`id DESC`), so
    /// a cursor derived from a local row disagrees with the relay about which rows in
    /// the *same second* are older — and a channel whose scrollback is mostly join
    /// notices has plenty of shared seconds.
    ///
    /// So the seed does not take the local row's id at all. It asks from
    /// `(floor.createdAt, 0…0)`, which under the relay's predicate
    /// (`created_at < ts OR (created_at = ts AND id > before_id)`) is every row at that
    /// second and everything below it. The boundary second comes back twice; the log is
    /// id-addressed, so the duplicates cost a dedupe and skip nothing. Erring the other
    /// way would silently drop rows a reader would never learn were missing.
    ///
    /// # Notices
    ///
    /// The kinds asked for are messages **and** `kind:40099` relay notices. A notice is
    /// stored by the relay through `insert_event` and so has no `thread_metadata` row —
    /// but the window query left-joins that table and admits `depth IS NULL` rows
    /// (`get_channel_window_on`, `buzz-db/src/thread.rs`), so a notice *is* a window row
    /// when the request's `kinds` allow one. Desktop's own window request carries 40099
    /// for exactly this reason. Without it, scrolling back would page messages while the
    /// join and leave rows between them stopped at whatever
    /// ``SyncEngineConfig/noticeBackfillLimit`` had reached, and the timeline would
    /// quietly become a different, shallower thing the further back it went.
    ///
    /// The watermark is deliberately untouched: this page says nothing about the gap
    /// between the head and the watermark, which is the only thing that contract
    /// describes (rule 3). Pages committed here are ordinary log rows.
    @discardableResult
    func loadOlderHistory(channel: String, before floor: WindowCursor) async throws -> OlderHistoryPage {
        guard !isStopped, state == .running else { throw OlderHistoryError.notRunning }
        guard !windowDegraded else { throw OlderHistoryError.unavailable }

        let filter = WindowFilter(
            channelID: channel,
            cursor: .after(cursor(for: channel, below: floor)),
            // The same set the timeline reads back, huddle rows included: a kind the live
            // subscription delivers but the history page does not is a row that exists
            // until the reader scrolls past it and then does not.
            kinds: [.channelMessage, .systemMessage, .huddleStarted, .huddleEnded],
            limit: config.windowPageLimit
        )
        guard let result = try? await windowClient.fetch(filter) else {
            // The request could not be formed (signer/encoder), which is the same
            // class of thing as the socket being down: retriable, not exhaustion.
            throw OlderHistoryError.notRunning
        }

        switch result {
        case let .page(page):
            // A page whose write threw is not a page this device has. Nothing it carries
            // may be acted on: advancing the cursor past it would skip its rows until
            // sign-out — ``historyCursors`` outlives the screen, the channel and the
            // socket, and unlike ``SyncEngine/reconcile(_:generation:)`` there is no
            // watermark here to re-anchor from — and echoing its `hasMore` would let a
            // failed write latch as "this channel begins here" over rows that exist.
            // Reconcile's identically-shaped `try?` is safe for the opposite reason: its
            // watermark advances inside the same transaction.
            guard let outcome = try? await store.commitWindowPage(
                page, channel: channel, advanceWatermarkTo: nil
            ) else {
                throw OlderHistoryError.notIngested
            }
            if let next = page.bounds.nextCursor { historyCursors[channel] = next }
            return OlderHistoryPage(hasMore: page.bounds.hasMore, ingested: outcome.inserted.count)

        case .invalidPage:
            throw OlderHistoryError.invalidPage

        case .degraded:
            // Same withdrawal the reconcile path records, and it lifts the same way:
            // at the next `.ready`. There is no fallback to run here — the standard
            // filter has no cursor below the head, which is the whole ask.
            windowDegraded = true
            throw OlderHistoryError.unavailable
        }
    }

    /// This channel's next scrollback cursor: the relay's own once there is one, and
    /// the local floor only to start the chain.
    ///
    /// The caller's floor is deliberately **not** consulted again after that, and both
    /// ways of "improving" on it are wrong:
    ///
    /// - Taking whichever is deeper stalls. The seed drops the id (`0…0`, see above), so
    ///   inside a single crowded second — fifty join notices sharing a `created_at` is
    ///   the ordinary case in a big channel — the seed always compares older than a chain
    ///   cursor at that same second. The request would reset to the top of that second on
    ///   every call, re-fetch the same page, ingest nothing new, and never move: the
    ///   permanent spinner this work exists to remove, rebuilt one layer down.
    /// - Re-seeding whenever the floor overtakes the chain skips rows. A reconcile
    ///   running underneath deepens the local store with `kind:9` only, so the stretch it
    ///   just filled has no notices in it; jumping the chain past that stretch is exactly
    ///   how those notices would go permanently unreachable.
    ///
    /// So the chain re-walks a range the store may already hold, which costs a round trip
    /// per page and adds the notices that range was missing. Following the relay's own
    /// cursor is also the only thing that makes paging provably gap-free.
    private func cursor(for channel: String, below floor: WindowCursor) -> WindowCursor {
        historyCursors[channel] ?? WindowCursor(
            createdAt: floor.createdAt, id: String(repeating: "0", count: 64)
        )
    }
}
