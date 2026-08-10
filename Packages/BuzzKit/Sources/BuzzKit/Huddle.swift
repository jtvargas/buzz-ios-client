import Foundation
import GRDB
import NostrCore

extension Schema {
    /// The table behind ``ChannelListRow/isHuddle``.
    ///
    /// Spelled here rather than inline in `Schema` so it sits beside the projector that
    /// fills it, and because that enum's body is already over swiftlint's
    /// `type_body_length` warning — the same reason ``createThreadSweepTable(_:)`` lives
    /// in `ThreadSweep.swift`.
    ///
    /// # Why a huddle needs a table at all
    ///
    /// Because a huddle channel is not marked as one. The relay creates it as an ordinary
    /// `stream` channel with a TTL — verified on a live relay, whose kind-39000 for a
    /// running huddle reads `[["name","… huddle"],["t","stream"],["ttl","3600"],…]` and
    /// carries nothing else to go on. The only thing that says "this channel is a huddle"
    /// is the kind-48100 published in the *parent* channel, whose body names it. So the
    /// link has to be recorded when that event is projected; the alternative — matching a
    /// channel whose name happens to end in "huddle" — is a guess that a channel called
    /// "design huddle" would fail.
    ///
    /// Keyed on the huddle's own channel id because that is the only question asked of it:
    /// the sidebar has a channel row in hand and needs to know what kind of room it is.
    static func createHuddleTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE huddle (
            -- The ephemeral channel the huddle runs in: `ephemeral_channel_id` from the
            -- lifecycle event's body, and the id a `channel` row is keyed by.
            channel_id TEXT PRIMARY KEY NOT NULL,
            -- The channel it was started from — the lifecycle event's `h` scope, which is
            -- where the "started a huddle" row is read.
            parent_id  TEXT NOT NULL,
            started_at INTEGER NOT NULL
        )
        """)
    }
}

extension BuzzProjector {
    /// Kinds 48100 and 48103: a huddle started, and a huddle ended.
    ///
    /// Both are recorded, and both write the same row. That is deliberate and it is what
    /// makes the projection independent of arrival order: an end that lands before its
    /// start — a resend after a reconnect, or a rebuild replaying in id order — still
    /// leaves the channel correctly known to be a huddle, and `started_at` settles on the
    /// earlier of the two once both are in. A projection that only learned this from the
    /// start event would answer differently depending on the order the log was replayed
    /// in, which is exactly what the rebuild path must not do.
    ///
    /// An unreadable body records nothing rather than a partial row: the channel id *is*
    /// the fact here, so there is no half of it worth keeping.
    static func projectHuddle(_ event: NostrEvent, into db: Database) throws {
        guard let parent = event.groupID,
              let body = try? JSONDecoder().decode(HuddleBody.self, from: Data(event.content.utf8)),
              !body.ephemeralChannelID.isEmpty
        else { return }

        try db.execute(
            sql: """
            INSERT INTO huddle (channel_id, parent_id, started_at) VALUES (?, ?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET
                started_at = MIN(huddle.started_at, excluded.started_at)
            """,
            arguments: [body.ephemeralChannelID, parent, event.createdAt]
        )
    }

    /// The body every huddle lifecycle kind carries — verified identical on 48100, 48101,
    /// 48102 and 48103 against a live relay.
    private struct HuddleBody: Decodable {
        let ephemeralChannelID: String

        enum CodingKeys: String, CodingKey {
            case ephemeralChannelID = "ephemeral_channel_id"
        }
    }
}
