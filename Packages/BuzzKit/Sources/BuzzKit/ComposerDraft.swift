import Foundation
import GRDB

/// One conversation's unsent composer text as stored.
///
/// `rootID` names the thread the draft belongs to, or is `nil` for the channel's own
/// composer. That distinction is the point of the whole feature — a channel and each of
/// its threads hold separate drafts — so it is carried in the type rather than left to
/// callers to encode.
///
/// `tokens` is opaque here. BuzzKit has no notion of a mention token; the app layer
/// encodes its own and this layer round-trips the string unread.
public struct ComposerDraftRecord: Sendable, Equatable {
    public let channelID: String
    public let rootID: String?
    public let text: String
    public let tokens: String
    /// When this draft was last edited, in **milliseconds** since the epoch — the order
    /// the capacity trim evicts in. Milliseconds rather than the seconds every other
    /// timestamp in this store uses, because those come off the wire and this one exists
    /// only to rank two of a person's own edits, which are routinely under a second apart.
    public let updatedAt: Int64

    public init(channelID: String, rootID: String?, text: String, tokens: String, updatedAt: Int64) {
        self.channelID = channelID
        self.rootID = rootID
        self.text = text
        self.tokens = tokens
        self.updatedAt = updatedAt
    }
}

/// One draft as a *list* reads it: where it belongs, enough of it to recognise, and when
/// it was last touched.
///
/// Distinct from ``ComposerDraftRecord`` because the two answer different questions. A
/// record is the draft, and exists to be put back into a composer. A summary is a row on
/// a screen, and its text is clipped in SQL — a draft may run to the 64 KiB message
/// ceiling, the row shows one line of it, and the list is re-read on every keystroke the
/// author makes anywhere. Reading the whole column to draw a hundred single lines is the
/// one shape of this feature that could actually cost something.
public struct ComposerDraftSummary: Sendable, Equatable, Identifiable {
    public let channelID: String
    public let rootID: String?
    /// The draft's opening characters — see ``ComposerDraftPolicy/snippetLength``. Never
    /// the whole draft.
    public let snippet: String
    public let updatedAt: Int64

    /// Stable across re-reads, so a list keeps a row's identity while its text changes.
    /// The composer's coordinate, which is exactly what a row stands for.
    public var id: String { "\(channelID)\u{1F}\(rootID ?? "")" }

    public init(channelID: String, rootID: String?, snippet: String, updatedAt: Int64) {
        self.channelID = channelID
        self.rootID = rootID
        self.snippet = snippet
        self.updatedAt = updatedAt
    }
}

public enum ComposerDraftPolicy {
    /// How many conversations may hold a draft at once. Beyond this, the least recently
    /// edited one is dropped on the next save.
    ///
    /// A cap rather than none, because a draft is retained plaintext and nothing else
    /// ever deletes one: a conversation typed into and abandoned in 2026 would otherwise
    /// still be on the device years later. There is no *processing* argument for a cap —
    /// the lookup is a primary-key hit whatever the row count — so the number is set by
    /// the opposite risk. Eviction is silent data loss, which is the exact failure this
    /// feature exists to prevent, so it must sit far past what a person can reach: a
    /// hundred conversations with unsent text in them is not a state anyone arrives at by
    /// accident, while ten is one busy morning.
    public static let capacity = 100

    /// How much of a draft a list row reads. Comfortably more than one line at any text
    /// size, so the row truncates from a string it already holds rather than asking for
    /// more; small enough that the whole screen is a few kilobytes however long the drafts
    /// behind it are.
    public static let snippetLength = 200
}

/// The composer-draft seam onto the store.
///
/// Reads are `nonisolated` and synchronous, like ``BuzzEventStore/timeline(channel:before:limit:)``,
/// because the caller is a conversation opening: the draft has to be in the composer on
/// the first layout, and anything asynchronous shows an empty bar first and fills it in
/// afterwards. It is a primary-key lookup of one small row.
///
/// Writes go through the actor like every other mutation.
public extension BuzzEventStore {
    /// The draft for one composer, or `nil` when it holds nothing.
    ///
    /// - Parameter root: the thread's root id, or `nil` for the channel's own composer.
    nonisolated func composerDraft(channel: String, root: String?) throws -> ComposerDraftRecord? {
        try reader.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT text, tokens, updated_at FROM composer_draft WHERE channel_id = ? AND root_id = ?",
                arguments: [channel, root ?? ""]
            )
            .map { row in
                ComposerDraftRecord(
                    channelID: channel,
                    rootID: root,
                    text: row["text"],
                    tokens: row["tokens"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    /// Every stored draft, newest edit first. For tests and diagnostics; the app reads
    /// one composer at a time.
    nonisolated func composerDrafts() throws -> [ComposerDraftRecord] {
        try reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT channel_id, root_id, text, tokens, updated_at
                FROM composer_draft ORDER BY updated_at DESC
                """
            )
            .map { row in
                let root: String = row["root_id"]
                return ComposerDraftRecord(
                    channelID: row["channel_id"],
                    rootID: root.isEmpty ? nil : root,
                    text: row["text"],
                    tokens: row["tokens"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    /// Writes one composer's draft, replacing whatever that composer held, and trims the
    /// table back to `capacity` by least recent edit.
    ///
    /// Empty text deletes instead of storing a blank row: a cleared composer holds no
    /// draft, and a blank row would occupy a capacity slot and restore as nothing.
    /// Whitespace is not text — a draft that could never be sent is never kept, and the
    /// predicate is spelled exactly as the cache above this spells it, so the two can
    /// never disagree about whether a composer holds anything.
    func saveComposerDraft(
        channel: String,
        root: String?,
        text: String,
        tokens: String,
        keeping capacity: Int = ComposerDraftPolicy.capacity
    ) async throws {
        guard !text.allSatisfy(\.isWhitespace) else {
            try await deleteComposerDraft(channel: channel, root: root)
            return
        }
        let updatedAt = Int64((clock().timeIntervalSince1970 * 1000).rounded())
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO composer_draft (channel_id, root_id, text, tokens, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (channel_id, root_id) DO UPDATE SET
                    text = excluded.text, tokens = excluded.tokens, updated_at = excluded.updated_at
                """,
                arguments: [channel, root ?? "", text, tokens, updatedAt]
            )
            // The survivors are chosen by an index walk — `EXPLAIN QUERY PLAN` reports
            // `SCAN ... USING COVERING INDEX composer_draft_recency` for the subquery —
            // and the delete then scans, which over a table bounded at a hundred rows is
            // nothing. The tie-break is `rowid` *ascending* rather than descending
            // deliberately: an index carries its rowids ascending, so this direction is
            // satisfied by the walk while the other adds a temp B-tree sort. It only
            // decides between two drafts edited in the same millisecond, and it exists so
            // that which one survives is a function of the data rather than of storage
            // order — the reasoning ``ThreadReadMarks/pruned(_:)`` records for its own.
            try db.execute(
                sql: """
                DELETE FROM composer_draft WHERE rowid NOT IN (
                    SELECT rowid FROM composer_draft ORDER BY updated_at DESC, rowid LIMIT ?
                )
                """,
                arguments: [max(1, capacity)]
            )
        }
    }

    /// Drops one composer's draft — sending, or clearing the field by hand.
    func deleteComposerDraft(channel: String, root: String?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM composer_draft WHERE channel_id = ? AND root_id = ?",
                arguments: [channel, root ?? ""]
            )
        }
    }

    // MARK: - The Drafts screen

    /// Every stored draft as a list row, most recently edited first.
    ///
    /// The text is clipped in SQL rather than in Swift — see ``ComposerDraftSummary``.
    nonisolated func composerDraftSummaries(
        snippetLength: Int = ComposerDraftPolicy.snippetLength
    ) throws -> [ComposerDraftSummary] {
        try reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT channel_id, root_id, substr(text, 1, ?) AS snippet, updated_at
                FROM composer_draft ORDER BY updated_at DESC, rowid
                """,
                arguments: [max(1, snippetLength)]
            )
            .map { row in
                let root: String = row["root_id"]
                return ComposerDraftSummary(
                    channelID: row["channel_id"],
                    rootID: root.isEmpty ? nil : root,
                    snippet: row["snippet"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    /// How many composers are holding unsent text. The shortcut card's number, read on its
    /// own rather than as `summaries.count` so the sidebar never carries the text.
    nonisolated func composerDraftCount() throws -> Int {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM composer_draft") ?? 0
        }
    }

    /// Discards several drafts at once — the Drafts screen's delete.
    ///
    /// One transaction, so a multi-selection either goes or does not: a partial delete
    /// would leave the reader looking at a list they have to work out the state of.
    func deleteComposerDrafts(_ keys: [(channel: String, root: String?)]) async throws {
        guard !keys.isEmpty else { return }
        try await writer.write { db in
            for key in keys {
                try db.execute(
                    sql: "DELETE FROM composer_draft WHERE channel_id = ? AND root_id = ?",
                    arguments: [key.channel, key.root ?? ""]
                )
            }
        }
    }
}
