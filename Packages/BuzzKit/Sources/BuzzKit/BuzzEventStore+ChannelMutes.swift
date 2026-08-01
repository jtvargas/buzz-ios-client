import Foundation
import GRDB

/// The channel-mute seam onto the store: the merge of a decrypted `kind:30078`
/// `channel-mutes` blob into the local table, the read-back that builds the next
/// blob, and the cursor that keeps the next publish strictly newer than the last.
///
/// Mutes are a *precious local* table, not a projection — see the `v9.channel-mutes`
/// migration for why the keyless projector cannot rebuild them. The engine, which
/// holds the identity, decrypts an incoming blob and calls
/// ``applyChannelMutes(_:sourceCreatedAt:sourceEventID:)``; the store never touches
/// the secret.
public extension BuzzEventStore {
    /// Every channel id currently muted. The set the sidebar asks for — the unmuted
    /// records stay in the table, because an unmute is a record and not an absence.
    nonisolated func mutedChannelIDs() throws -> Set<String> {
        try reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT channel_id FROM channel_mute WHERE muted = 1"))
        }
    }

    /// Whether one channel is muted.
    nonisolated func isChannelMuted(_ channel: String) throws -> Bool {
        try reader.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT muted FROM channel_mute WHERE channel_id = ?",
                arguments: [channel]
            ) ?? false
        }
    }
}

extension BuzzEventStore {
    /// The whole mute table plus the cursor of the newest blob it was built from —
    /// what the engine reads to encode the next blob and stamp it strictly newer.
    struct ChannelMuteState: Sendable, Equatable {
        /// Every channel with a decision on record, muted and unmuted alike.
        let entries: [String: ChannelMuteEntry]
        /// The `created_at` of the newest blob adopted or published, or 0 when none.
        let sourceCreatedAt: Int64
    }

    func channelMuteState() async throws -> ChannelMuteState {
        try await reader.read { db in try Self.readChannelMuteState(db) }
    }

    /// Records this device's own decision about one channel, returning the whole table
    /// as it now stands so the caller can encode it without a second read.
    ///
    /// The local write lands whether or not the publish that follows ever succeeds: a
    /// toggle that only took effect once the relay answered would read as broken on a
    /// train, and the blob is rebuilt from this table on the next change anyway.
    @discardableResult
    func setChannelMute(_ channel: String, muted: Bool, updatedAt: Int64) async throws -> ChannelMuteState {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO channel_mute (channel_id, muted, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    muted = excluded.muted,
                    updated_at = excluded.updated_at
                """,
                arguments: [channel, muted, updatedAt]
            )
            return try Self.readChannelMuteState(db)
        }
    }

    /// Merges one decrypted remote blob — per-channel last-writer-wins by each entry's
    /// own `updatedAt`, never a wholesale replace.
    ///
    /// This is the difference from read state, and it is deliberate. Read state is
    /// *per-installation*: each device owns its own `d` coordinate, so replacing a slot
    /// wholesale is correct. Mutes have one coordinate for the whole identity, so two
    /// devices write the *same* addressable event — and the newer event is not
    /// automatically the newer truth about every channel inside it, because a phone that
    /// has been offline for a day can publish last while holding yesterday's opinion.
    /// The per-entry timestamps are the only thing that can settle that, which is why
    /// they are on the wire at all.
    ///
    /// The `(created_at, id)` cursor therefore guards only the *cursor*, never the
    /// merge: an older blob can still carry a newer entry, and rejecting it wholesale
    /// would drop that entry on the floor.
    ///
    /// Returns whether any channel's answer actually changed, so a caller can decline
    /// the republish that would otherwise ping-pong between two devices for ever.
    @discardableResult
    func applyChannelMutes(
        _ incoming: [String: ChannelMuteEntry],
        sourceCreatedAt: Int64,
        sourceEventID: String
    ) async throws -> Bool {
        try await writer.write { db in
            var changed = false
            for (channelID, entry) in incoming {
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT muted, updated_at FROM channel_mute WHERE channel_id = ?",
                    arguments: [channelID]
                ) {
                    let existingUpdatedAt: Int64 = existing["updated_at"]
                    guard entry.updatedAt > existingUpdatedAt else { continue }
                    // A newer stamp that says the same thing is still worth storing —
                    // it is what keeps the next comparison honest — but it is not a
                    // change anyone needs to hear about.
                    let existingMuted: Bool = existing["muted"]
                    if entry.muted != existingMuted { changed = true }
                } else {
                    changed = true
                }
                try db.execute(
                    sql: """
                    INSERT INTO channel_mute (channel_id, muted, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(channel_id) DO UPDATE SET
                        muted = excluded.muted,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [channelID, entry.muted, entry.updatedAt]
                )
            }
            try Self.advanceChannelMuteCursor(db, createdAt: sourceCreatedAt, eventID: sourceEventID)
            return changed
        }
    }

    /// Records the cursor of a blob this device just published, so the next one is
    /// stamped strictly newer without waiting for the relay's echo.
    func recordPublishedChannelMutes(sourceCreatedAt: Int64, sourceEventID: String) async throws {
        try await writer.write { db in
            try Self.advanceChannelMuteCursor(db, createdAt: sourceCreatedAt, eventID: sourceEventID)
        }
    }

    // MARK: - Shared

    /// Moves the cursor forward only. A reconnect replays the latest addressable blob,
    /// and letting an older stamp win would lower the bar the next publish has to clear.
    private static func advanceChannelMuteCursor(_ db: Database, createdAt: Int64, eventID: String) throws {
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT source_created_at FROM channel_mute_source WHERE id = 0"
        ) ?? 0
        guard createdAt > current else { return }
        try db.execute(
            sql: """
            INSERT INTO channel_mute_source (id, source_created_at, source_event_id)
            VALUES (0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_created_at = excluded.source_created_at,
                source_event_id = excluded.source_event_id
            """,
            arguments: [createdAt, eventID]
        )
    }

    private static func readChannelMuteState(_ db: Database) throws -> ChannelMuteState {
        var entries: [String: ChannelMuteEntry] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT channel_id, muted, updated_at FROM channel_mute") {
            let channelID: String = row["channel_id"]
            entries[channelID] = ChannelMuteEntry(muted: row["muted"], updatedAt: row["updated_at"])
        }
        let cursor = try Int64.fetchOne(
            db,
            sql: "SELECT source_created_at FROM channel_mute_source WHERE id = 0"
        )
        return ChannelMuteState(entries: entries, sourceCreatedAt: cursor ?? 0)
    }
}
