import Foundation
import GRDB
import NostrCore

/// The sync-engine seam onto the store: the durable per-channel watermark, the
/// watermark-advancing live ingest, and the window-page commit — each routed
/// through the *same* verification choke point and transaction discipline as
/// ``BuzzEventStore/ingest(batch:phase:)``.
///
/// Two invariants the engine (step 6) leans on live here rather than in the
/// engine, because both turn on a single GRDB transaction the store owns:
///
/// - **The watermark advances only alongside the events that justify it.** A live
///   flush advances a synced channel's watermark in the *same* transaction as the
///   batch (rule 4); a reconcile advances the gap-closing channel's watermark in
///   the *same* transaction as the page that closes the gap (rule 3). Split across
///   two transactions, a crash between them could leave a watermark claiming
///   contiguity the log does not have — the one failure mode the composite cursor
///   exists to prevent.
/// - **The advance never regresses.** `created_at` is author-controlled, and a
///   relay can resend an older row after a reconnect, so every advance is a
///   `max` against the stored cursor: an older event stores fine and leaves the
///   watermark where it was.
public extension BuzzEventStore {
    // MARK: - Watermark reads

    /// The durable composite `(created_at, id)` watermark for a channel — the
    /// newest cursor below which local history is contiguous — or `nil` when the
    /// channel has never been reconciled.
    func channelWatermark(_ channel: String) async throws -> WindowCursor? {
        try await reader.read { db in
            try Self.readWatermark(channel, from: db)?.cursor
        }
    }

    /// Every channel the store already knows about: those carrying a durable
    /// watermark and those with projected metadata. The engine reconciles the
    /// union of these and the channels freshly discovered on a socket, so a
    /// channel known only from a prior session is still caught up on relaunch even
    /// before its metadata is re-served.
    func knownChannels() async throws -> Set<String> {
        try await reader.read { db in
            var channels = Set<String>()
            channels.formUnion(try String.fetchAll(db, sql: "SELECT channel_id FROM channel_sync"))
            channels.formUnion(try String.fetchAll(db, sql: "SELECT id FROM channel"))
            return channels
        }
    }

    /// Every distinct member pubkey across every known channel roster — the authors a
    /// cold-start presence-snapshot REQ names. Read from the `channel_member`
    /// projection the discovery pass populates, so it is available the moment group
    /// state lands, before any heartbeat.
    func allMemberPubkeys() async throws -> Set<String> {
        try await reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT pubkey FROM channel_member"))
        }
    }

    // MARK: - Watermark-advancing ingest (live phase)

    /// Ingests a batch and, in the same transaction, advances the watermark for
    /// each channel in `synced` to `max(watermark, batch's newest message cursor)`.
    ///
    /// Rule 4: only a channel the engine has reconciled to `synced` advances; an
    /// unsynced channel's live events still ingest, but its watermark holds because
    /// they may sit above an open gap. The advance is computed from the admitted
    /// kind-9 events scoped to the channel (the same order space the window rows
    /// occupy), so a reaction or an out-of-band kind never moves it.
    ///
    /// - Note: Known limitation. This live advance trusts each message's
    ///   author-controlled `created_at`. A future-skewed message can therefore push
    ///   a synced channel's watermark ahead of true time, so a later reconcile —
    ///   which pages down only until it reaches the stored watermark — may skip
    ///   honestly-timestamped events created inside that skew window. The exposure is
    ///   bounded, not unbounded: the relay's ingest gate rejects any event whose
    ///   `created_at` is more than ±15 minutes from server time
    ///   (`buzz-relay .../ingest.rs`), so the largest possible early advance is that
    ///   window.
    ///
    ///   This note used to close by saying the ±15-minute bound "keeps it within the live
    ///   overlap the reconcile already re-fetches". That is wrong, and it is the reason
    ///   this was recorded rather than fixed: the live replay overlap is
    ///   ``SubscriptionManagerConfig/replayOverlapSeconds``, five seconds, which does not
    ///   cover a fifteen-minute window. Nothing re-fetches the difference.
    ///
    ///   Still recorded rather than fixed, but for the honest reason. The obvious clamp —
    ///   `min(cursor.createdAt, now)` — is what
    ///   ``NostrCore/SubscriptionManager`` does to its replay cursor, and it is safe there
    ///   because that cursor is a bare timestamp. This one is a composite
    ///   `(created_at, id)` keyset position, so clamping the timestamp while keeping the
    ///   id would leave a cursor that names no row the walk can resume from. The correct
    ///   fix is to withhold the advance from a future-stamped message rather than to
    ///   truncate it, which is a change to ``maxMessageCursor(in:forChannel:)`` and its
    ///   own piece of work.
    @discardableResult
    func ingest(
        batch: [NostrEvent],
        phase _: IngestPhase,
        advancingWatermarksIn synced: Set<String>
    ) async throws -> IngestResult {
        guard !batch.isEmpty else { return IngestResult() }

        let (writable, partition) = await Self.admit(batch)
        var result = partition

        // Computed off-lock from the admitted events; a channel with no message in
        // this batch contributes no advance.
        let advances: [(channel: String, cursor: WindowCursor)] = synced.compactMap { channel in
            Self.maxMessageCursor(in: writable, forChannel: channel).map { (channel, $0) }
        }

        guard !writable.isEmpty || !advances.isEmpty else { return result }

        let receivedAt = Int64(clock().timeIntervalSince1970)
        let projector = projector
        let toWrite = writable
        let outcome = try await writer.write { db -> WriteCounts in
            let counts = try Self.writeAdmitted(toWrite, receivedAt: receivedAt, projector: projector, into: db)
            for advance in advances {
                try Self.advanceWatermark(advance.channel, to: advance.cursor, markHeadSynced: false, into: db)
            }
            return counts
        }
        result.inserted = outcome.inserted
        result.duplicates = outcome.duplicates
        return result
    }

    // MARK: - Window-page commit (reconcile phase)

    /// Commits one reconcile window page — its rows, aux closure, and summaries all
    /// through the verification choke point — and, only when `advanceWatermarkTo`
    /// is non-nil, advances the channel watermark to `max(watermark, that cursor)`
    /// in the same transaction.
    ///
    /// Rule 3: the engine passes the head page's newest cursor here exactly once,
    /// on the transaction that commits the gap-closing page, and passes `nil` for
    /// every intermediate page. A crash before the gap-closing commit therefore
    /// leaves the watermark untouched, and the next launch re-pages from the head —
    /// free, because the id-addressed log dedupes the overlap.
    @discardableResult
    func commitWindowPage(
        _ page: WindowPage,
        channel: String,
        advanceWatermarkTo headNewest: WindowCursor?
    ) async throws -> IngestResult {
        let events = page.rows + page.aux + page.summaries
        let (writable, partition) = await Self.admit(events)
        var result = partition

        // A page that is all duplicates still has to be able to commit the
        // gap-closing watermark advance, so the transaction opens whenever there is
        // anything to write or a watermark to move.
        guard !writable.isEmpty || headNewest != nil else { return result }

        let receivedAt = Int64(clock().timeIntervalSince1970)
        let projector = projector
        let toWrite = writable
        let outcome = try await writer.write { db -> WriteCounts in
            let counts = try Self.writeAdmitted(toWrite, receivedAt: receivedAt, projector: projector, into: db)
            if let headNewest {
                try Self.advanceWatermark(channel, to: headNewest, markHeadSynced: true, into: db)
            }
            return counts
        }
        result.inserted = outcome.inserted
        result.duplicates = outcome.duplicates
        return result
    }

    /// Records that this device now holds a thread in full, naming the relay summary
    /// that fetch supersedes.
    ///
    /// Called after ``SyncEngine/openThread(root:)`` has ingested a thread's replies,
    /// and it is what lets the reply tally prefer this device's own count from then on
    /// — including down, when a summary the relay pushed into a dropped frame is still
    /// advertising a reply that has since been withdrawn.
    ///
    /// The summary is captured in the same statement that writes the row rather than
    /// read first and passed in, so a summary arriving between the two can only ever be
    /// recorded as *not* accounted for. That is the safe direction: the reader then
    /// prefers the relay for one more round instead of suppressing a correction.
    func recordThreadFetch(root: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO thread_fetch (root_id, summary_event_id)
                VALUES (?, (SELECT event_id FROM thread_summary WHERE root_id = ?))
                ON CONFLICT(root_id) DO UPDATE SET summary_event_id = excluded.summary_event_id
                """,
                arguments: [root, root]
            )
        }
    }
}

// MARK: - Shared internals

extension BuzzEventStore {
    /// The insert/duplicate split, `Sendable` out of the write closure so the
    /// result is assembled on the actor.
    struct WriteCounts: Sendable {
        var inserted: [String] = []
        var duplicates: [String] = []
    }

    /// Verifies a batch through the single choke point, then partitions it into the
    /// events to write and the reported outcome (ephemerals diverted, forgeries
    /// rejected). The duplicate split is deferred to the write, where `ON CONFLICT`
    /// decides it.
    static func admit(_ batch: [NostrEvent]) async -> (writable: [NostrEvent], result: IngestResult) {
        let verdicts = await verify(batch)
        var result = IngestResult()
        var writable: [NostrEvent] = []
        writable.reserveCapacity(batch.count)
        for (event, verdict) in zip(batch, verdicts) {
            switch verdict {
            case .idMismatch:
                result.rejected.append(Rejection(id: event.id, reason: .idMismatch))
            case .badSignature:
                result.rejected.append(Rejection(id: event.id, reason: .badSignature))
            case .valid:
                if event.kind.isEphemeral {
                    result.ephemeral.append(event)
                } else {
                    writable.append(event)
                }
            }
        }
        return (writable, result)
    }

    /// Writes each already-admitted event through ``write(_:receivedAt:projector:into:)``,
    /// accumulating the insert/duplicate split.
    static func writeAdmitted(
        _ writable: [NostrEvent],
        receivedAt: Int64,
        projector: any EventProjecting,
        into db: Database
    ) throws -> WriteCounts {
        var counts = WriteCounts()
        for event in writable {
            if try write(event, receivedAt: receivedAt, projector: projector, into: db) {
                counts.inserted.append(event.id)
            } else {
                counts.duplicates.append(event.id)
            }
        }
        return counts
    }

    /// The newest `(created_at, id)` cursor among a batch's top-order messages
    /// (kind 9) scoped to one channel — the order space the window rows and the
    /// watermark share.
    static func maxMessageCursor(in events: [NostrEvent], forChannel channel: String) -> WindowCursor? {
        events
            .filter { $0.kind == .channelMessage && $0.groupID == channel }
            .map { WindowCursor(createdAt: $0.createdAt, id: $0.id) }
            .max()
    }

    /// The persisted watermark row, split into its optional cursor and the
    /// head-synced flag.
    struct WatermarkRow {
        let cursor: WindowCursor?
        let headSynced: Bool
    }

    static func readWatermark(_ channel: String, from db: Database) throws -> WatermarkRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT watermark_created_at, watermark_id, head_synced FROM channel_sync WHERE channel_id = ?",
            arguments: [channel]
        ) else { return nil }
        let createdAt: Int64? = row["watermark_created_at"]
        let id: String? = row["watermark_id"]
        let headSynced: Int64 = row["head_synced"]
        let cursor: WindowCursor? = if let createdAt, let id {
            WindowCursor(createdAt: createdAt, id: id)
        } else {
            nil
        }
        return WatermarkRow(cursor: cursor, headSynced: headSynced != 0)
    }

    /// Upserts the channel watermark to `max(existing, cursor)`, never regressing,
    /// preserving a set head-synced flag and raising it when `markHeadSynced`.
    static func advanceWatermark(
        _ channel: String,
        to cursor: WindowCursor,
        markHeadSynced: Bool,
        into db: Database
    ) throws {
        let existing = try readWatermark(channel, from: db)
        let target: WindowCursor = if let current = existing?.cursor {
            Swift.max(current, cursor)
        } else {
            cursor
        }
        let headSynced = (existing?.headSynced ?? false) || markHeadSynced
        try db.execute(
            sql: """
            INSERT INTO channel_sync (channel_id, watermark_created_at, watermark_id, head_synced)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET
                watermark_created_at = excluded.watermark_created_at,
                watermark_id = excluded.watermark_id,
                head_synced = excluded.head_synced
            """,
            arguments: [channel, target.createdAt, target.id, headSynced ? 1 : 0]
        )
    }
}

// MARK: - Cursor ordering

/// The total order NIP-CW defines over a channel's timeline: `created_at` first,
/// the event id bytewise as the tiebreak (lowercase hex, so the string order is
/// the byte order). Watermark advances and the reconcile loop's "oldest row below
/// the watermark" test are both expressed against this ordering.
extension WindowCursor: Comparable {
    public static func < (lhs: WindowCursor, rhs: WindowCursor) -> Bool {
        (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }
}
