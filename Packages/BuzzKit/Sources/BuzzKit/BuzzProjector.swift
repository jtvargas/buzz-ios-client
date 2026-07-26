import Foundation
import GRDB
import NostrCore

/// Derives projection rows from a verified event.
///
/// Every case here is a pure function of the event: given the same event it writes
/// the same rows, so the live ingest path and the version-bump rebuild — both of
/// which call ``project(_:into:)`` — settle on identical projections. That is the
/// whole point of the seam; if a case is added or its meaning changes, bump
/// ``Schema/projectionVersion`` and the log replays.
///
/// Two rules run through every case:
///
/// - **The projector records; it does not judge.** Deletions and edits are stored
///   as raw facts whatever key signed them. Whether one takes effect is a
///   read-time decision (see the timeline query), because the authority rule needs
///   the target's author and its verified owner, and because keeping the judgment
///   out of the projection means an authority fix is a version bump, not a resync.
/// - **A collapsing replaceable never regresses.** Channel, profile, roster,
///   rich-content, and thread-summary rows keep only the newest source per key,
///   guarded so an older event a relay resends after a reconnect cannot overwrite
///   a newer one — and so the collapse lands the same row whatever order the log
///   is replayed in. The guard compares `(created_at, source_event_id)`, not
///   `created_at` alone: a relay hands out many events in one second, and a tie
///   broken by event id (bytewise, the NIP-CW total order) resolves a same-second
///   collision the *same* way in first-arrival live ingest and in the id-ordered
///   rebuild replay. Event-id dedupe alone is wrong for these.
struct BuzzProjector: EventProjecting {
    func project(_ event: NostrEvent, into db: Database) throws {
        // Owner attestation is orthogonal to kind: any event may carry one, and the
        // read-time authority predicate reads it for whichever event a deletion or
        // edit targets. Recorded first so it is present no matter what the switch
        // does with the event.
        try Self.projectOwnerAttestation(event, into: db)

        switch event.kind {
        case .groupMetadata:
            try Self.projectChannel(event, into: db)
        case .groupMembers:
            try Self.projectRoster(event, into: db)
        case .metadata:
            try Self.projectProfile(event, into: db)
        case .reaction:
            try Self.projectReaction(event, into: db)
        case .deletion, .groupDeleteEvent:
            try Self.projectDeletion(event, into: db)
        case .messageEdit:
            try Self.projectEdit(event, into: db)
        case .richMessage:
            try Self.projectRichContent(event, into: db)
        case .channelMessage:
            try Self.projectThread(event, into: db)
        case .threadSummary:
            try Self.projectThreadSummary(event, into: db)
        default:
            // Everything else needs no projection; the timeline reads the log
            // directly.
            try Self.projectAdditional(event, into: db)
        }
    }

    // MARK: - Owner attestation

    /// Records the verified NIP-OA owner of an attested event's author.
    ///
    /// The event itself was already verified at the ingest choke point, so this
    /// checks only the owner's signature over the attestation, not the event again.
    /// An absent, ambiguous, or unverifiable `auth` tag records nothing, so a
    /// forged attestation grants no authority — the owner clause of the read-time
    /// predicate simply never matches.
    private static func projectOwnerAttestation(_ event: NostrEvent, into db: Database) throws {
        guard let tag = NIPOA.authTag(in: event.tags),
              NIPOA.verify(authTag: tag, eventPubkey: event.pubkey)
        else { return }

        // Owner pubkey is at tag index 1, per NIP-OA.
        try db.execute(
            sql: """
            INSERT INTO event_owner (event_id, owner_pubkey) VALUES (?, ?)
            ON CONFLICT(event_id) DO NOTHING
            """,
            arguments: [event.id, tag[1]]
        )
    }

    // MARK: - Channels

    /// Kind 39000: channel metadata, relay-signed and addressable by `d`.
    private static func projectChannel(_ event: NostrEvent, into db: Database) throws {
        guard let id = event.addressableIdentifier else { return }
        let meta = try? JSONDecoder().decode(ChannelMetadata.self, from: Data(event.content.utf8))

        // Ignore anything staler than the metadata already held: a relay can resend
        // an older addressable after a reconnect, and the replace must not regress.
        try db.execute(
            sql: """
            INSERT INTO channel (id, name, about, picture, is_private, source_event_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                about = excluded.about,
                picture = excluded.picture,
                is_private = excluded.is_private,
                source_event_id = excluded.source_event_id,
                updated_at = excluded.updated_at
            WHERE excluded.updated_at > channel.updated_at
               OR (excluded.updated_at = channel.updated_at
                   AND excluded.source_event_id > channel.source_event_id)
            """,
            arguments: [
                id,
                meta?.name?.nilIfEmpty ?? event.firstValue(forTag: "name"),
                meta?.about?.nilIfEmpty ?? event.firstValue(forTag: "about"),
                meta?.picture?.nilIfEmpty ?? event.firstValue(forTag: "picture"),
                // NIP-29 marks a closed group with a bare `private` tag.
                event.tags.contains { $0.first == "private" },
                event.id,
                event.createdAt,
            ]
        )
    }

    /// Kind 39002: the relay-signed member roster.
    ///
    /// The roster is authoritative and complete, so it replaces rather than merges
    /// — a member removed upstream must disappear here too. It is also addressable
    /// state, so a staler roster resent after a reconnect is ignored, which also
    /// makes the replace order-independent under a rebuild.
    private static func projectRoster(_ event: NostrEvent, into db: Database) throws {
        guard let channelID = event.addressableIdentifier else { return }

        // Reject a roster no newer than the one already applied, comparing the whole
        // `(created_at, source_event_id)` cursor. Comparing `created_at` alone lets a
        // same-second tie go to first-arrival live but to the higher-id replay winner
        // under a rebuild; the id tiebreak makes both keep the same roster.
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT source_created_at, source_event_id FROM channel_member WHERE channel_id = ? LIMIT 1",
            arguments: [channelID]
        )
        if let existing {
            let appliedAt: Int64 = existing["source_created_at"]
            let appliedID: String = existing["source_event_id"]
            if (event.createdAt, event.id) <= (appliedAt, appliedID) { return }
        }

        try db.execute(sql: "DELETE FROM channel_member WHERE channel_id = ?", arguments: [channelID])

        for tag in event.tags where tag.first == "p" && tag.count > 1 {
            try db.execute(
                sql: """
                INSERT INTO channel_member (channel_id, pubkey, role, source_created_at, source_event_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(channel_id, pubkey) DO UPDATE SET
                    role = excluded.role,
                    source_created_at = excluded.source_created_at,
                    source_event_id = excluded.source_event_id
                """,
                arguments: [channelID, tag[1], tag.count > 2 ? tag[2] : nil, event.createdAt, event.id]
            )
        }
    }

    // MARK: - Profiles

    /// Kind 0: profile metadata, replaceable per pubkey.
    private static func projectProfile(_ event: NostrEvent, into db: Database) throws {
        let meta = try? JSONDecoder().decode(ProfileMetadata.self, from: Data(event.content.utf8))

        try db.execute(
            sql: """
            INSERT INTO profile (pubkey, display_name, picture, about, nip05, lud16, source_event_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(pubkey) DO UPDATE SET
                display_name = excluded.display_name,
                picture = excluded.picture,
                about = excluded.about,
                nip05 = excluded.nip05,
                lud16 = excluded.lud16,
                source_event_id = excluded.source_event_id,
                created_at = excluded.created_at
            WHERE excluded.created_at > profile.created_at
               OR (excluded.created_at = profile.created_at
                   AND excluded.source_event_id > profile.source_event_id)
            """,
            arguments: [
                event.pubkey,
                // `display_name` is the newer field; `name` is what most relays and
                // older clients actually populate.
                meta?.displayName?.nilIfEmpty ?? meta?.name?.nilIfEmpty,
                meta?.picture?.nilIfEmpty,
                meta?.about?.nilIfEmpty,
                meta?.nip05?.nilIfEmpty,
                meta?.lud16?.nilIfEmpty,
                event.id,
                event.createdAt,
            ]
        )
    }

    // MARK: - Reactions

    /// Kind 7: a reaction, keyed to its target event.
    private static func projectReaction(_ event: NostrEvent, into db: Database) throws {
        // NIP-25: the target is the last `e` tag; empty or "+" content is a like,
        // which the UI renders as a heart.
        guard let target = event.referencedEventIDs.last else { return }
        let emoji = event.content.isEmpty || event.content == "+" ? "❤️" : event.content

        try db.execute(
            sql: """
            INSERT INTO reaction (event_id, target_id, pubkey, emoji, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO NOTHING
            """,
            arguments: [event.id, target, event.pubkey, emoji, event.createdAt]
        )
    }

    // MARK: - Deletions

    /// Kinds 5 and 9005: a deletion, recorded without judging it.
    ///
    /// `kind` is kept so the read-time predicate can tell a NIP-29 relay tombstone
    /// (9005, honoured from anyone the relay accepted) from an author or owner
    /// deletion (5, honoured only from the target's author or its verified owner).
    private static func projectDeletion(_ event: NostrEvent, into db: Database) throws {
        // One deletion can name several targets. The row is keyed by
        // `(event_id, target_id)`, so every target tombstones — an `ON CONFLICT`
        // on `event_id` alone would keep only the first and silently drop the rest.
        for target in event.referencedEventIDs {
            try db.execute(
                sql: """
                INSERT INTO deletion (event_id, target_id, deleted_by, kind, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(event_id, target_id) DO NOTHING
                """,
                arguments: [event.id, target, event.pubkey, event.kind.rawValue, event.createdAt]
            )
        }
    }

    // MARK: - Buzz content overlays

    /// Kind 40003: an edit. Every edit is kept; the timeline picks the newest
    /// authorized one at read time, so no staleness guard is needed here.
    private static func projectEdit(_ event: NostrEvent, into db: Database) throws {
        guard let target = event.referencedEventIDs.last else { return }

        try db.execute(
            sql: """
            INSERT INTO edit (event_id, target_id, pubkey, content, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO NOTHING
            """,
            arguments: [event.id, target, event.pubkey, event.content, event.createdAt]
        )
    }

    /// Kind 40002: rich content, collapsed to the newest payload per target.
    private static func projectRichContent(_ event: NostrEvent, into db: Database) throws {
        guard let target = event.referencedEventIDs.last else { return }

        try db.execute(
            sql: """
            INSERT INTO rich_content (target_id, event_id, payload, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(target_id) DO UPDATE SET
                event_id = excluded.event_id,
                payload = excluded.payload,
                created_at = excluded.created_at
            WHERE excluded.created_at > rich_content.created_at
               OR (excluded.created_at = rich_content.created_at
                   AND excluded.event_id > rich_content.event_id)
            """,
            arguments: [target, event.id, event.content, event.createdAt]
        )
    }

    /// Kind 39005: a relay-signed thread-summary overlay, keyed by the root id it
    /// describes (its `d` binding) and collapsed latest-wins per root.
    private static func projectThreadSummary(_ event: NostrEvent, into db: Database) throws {
        guard let root = event.addressableIdentifier else { return }

        try db.execute(
            sql: """
            INSERT INTO thread_summary (root_id, event_id, payload, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(root_id) DO UPDATE SET
                event_id = excluded.event_id,
                payload = excluded.payload,
                updated_at = excluded.updated_at
            WHERE excluded.updated_at > thread_summary.updated_at
               OR (excluded.updated_at = thread_summary.updated_at
                   AND excluded.event_id > thread_summary.event_id)
            """,
            arguments: [root, event.id, event.content, event.createdAt]
        )
    }

    // MARK: - Threads

    /// Kind 9: records a message's place in a thread, when it has one.
    ///
    /// Only a real NIP-10 reply gets a row, which is what lets the channel timeline
    /// exclude replies with a single `NOT EXISTS` rather than decoding tag JSON for
    /// every message. `broadcast` marks a reply its author also echoed to the
    /// channel; it keeps its thread row but is let through to the channel too.
    private static func projectThread(_ event: NostrEvent, into db: Database) throws {
        let reference = event.threadReference
        guard let parent = reference.parentID, let root = reference.rootID else { return }

        try db.execute(
            sql: """
            INSERT INTO thread (event_id, root_id, parent_id, channel_id, pubkey, created_at, broadcast)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO NOTHING
            """,
            arguments: [
                event.id,
                root,
                parent,
                event.groupID,
                event.pubkey,
                event.createdAt,
                event.isBroadcastReply,
            ]
        )
    }
}

// MARK: - Content shapes

/// Kind 0 content. Every field is optional: relays serve whatever a client wrote,
/// including empty strings and absent keys.
private struct ProfileMetadata: Decodable {
    let name: String?
    let displayName: String?
    let picture: String?
    let about: String?
    let nip05: String?
    let lud16: String?

    enum CodingKeys: String, CodingKey {
        case name, picture, about, nip05, lud16
        case displayName = "display_name"
    }
}

/// Kind 39000 content, when the relay sends JSON rather than tags.
private struct ChannelMetadata: Decodable {
    let name: String?
    let about: String?
    let picture: String?
}

private extension String {
    /// Treats an empty string as absent, so a cleared field falls back to a tag or
    /// to nothing rather than persisting as a blank.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
