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
        case .groupAdmins:
            try Self.projectAdmins(event, into: db)
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
            INSERT INTO channel
                (id, name, about, topic, purpose, picture, is_private, is_archived,
                 channel_type, ttl_seconds, ttl_deadline, source_event_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                about = excluded.about,
                topic = excluded.topic,
                purpose = excluded.purpose,
                picture = excluded.picture,
                is_private = excluded.is_private,
                is_archived = excluded.is_archived,
                channel_type = excluded.channel_type,
                ttl_seconds = excluded.ttl_seconds,
                ttl_deadline = excluded.ttl_deadline,
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
                // Tag-only: the relay writes `topic`/`purpose` as tags and never into
                // the JSON content, so there is no `meta?` half to prefer here.
                event.firstValue(forTag: "topic")?.nilIfEmpty,
                event.firstValue(forTag: "purpose")?.nilIfEmpty,
                meta?.picture?.nilIfEmpty ?? event.firstValue(forTag: "picture"),
                // NIP-29 marks a closed group with a bare `private` tag.
                event.tags.contains { $0.first == "private" },
                event.tags.contains {
                    $0.count > 1
                        && $0[0].lowercased() == "archived"
                        && $0[1].lowercased() == "true"
                },
                channelType(of: event),
                event.firstValue(forTag: "ttl").flatMap(Int64.init),
                event.firstValue(forTag: "ttl_deadline")
                    .flatMap(rfc3339)
                    .map { Int64($0.timeIntervalSince1970) },
                event.id,
                event.createdAt,
            ]
        )
    }

    /// The relay writes `chrono::DateTime::to_rfc3339`, which may include fractional
    /// seconds. `ISO8601DateFormatter` requires separate option sets for the two shapes.
    private static func rfc3339(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// What kind of room this is, from the relay's own `["t", <type>]` on kind 39000 —
    /// `stream`, `forum`, or `dm`.
    ///
    /// A bare `["hidden"]` stands in when the `t` tag is absent. The relay emits that tag
    /// on one channel type and no other (`side_effects.rs`: the `hidden` hint, the
    /// participant `p` tags, and `t=dm` are pushed by the same `channel_type == "dm"`
    /// branch), so it is the same fact told twice — and the fallback is what lets a relay
    /// deployed before the `t` tag still identify a DM. Anything else stays `nil`, a
    /// *don't know*: a channel whose type never arrived must not read as a `stream`,
    /// because "not a DM" is then a guess presented as the relay's answer.
    private static func channelType(of event: NostrEvent) -> String? {
        if let type = event.firstValue(forTag: "t")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !type.isEmpty {
            return type
        }
        return event.tags.contains { $0.first == "hidden" } ? "dm" : nil
    }

    /// Kind 39002: the relay-signed member roster.
    ///
    /// The roster is authoritative and complete, so it replaces rather than merges
    /// — a member removed upstream must disappear here too. It is also addressable
    /// state, so a staler roster resent after a reconnect is ignored, which also
    /// makes the replace order-independent under a rebuild.
    ///
    /// # The role is at index 3, and 39001's is at index 2
    ///
    /// A member tag is the full NIP-01 `p` shape — `["p", pubkey, relay, petname]` —
    /// with the role in the petname slot and the relay hint left empty:
    ///
    /// ```
    /// ["p", "cca9537a…", "", "bot"]
    /// ```
    ///
    /// ``projectAdmins`` reads index 2 and is right to: kind 39001 writes the short
    /// three-element form. The two rosters genuinely disagree, which is why the same
    /// expression is correct in one and wrong in the other, and why reading index 2
    /// here silently stored `""` as every member's role — measured against the live
    /// relay, 5,078 of 5,078 member tags are four long with an empty index 2. That
    /// emptied `DirectorySnapshot.isAgent` for every identity, since its other source
    /// (kind 10100, `agent_directory`) has never had a single event on that relay.
    /// Index 2 is still read as a fallback so a roster in the short form is not
    /// silently roleless.
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
                arguments: [channelID, tag[1], memberRole(tag), event.createdAt, event.id]
            )
        }
    }

    /// The role carried by a kind-39002 `p` tag: the petname slot, falling back to the
    /// relay slot for the short form ``projectAdmins`` receives. Empty is `nil` rather
    /// than `""` so `LOWER(role) = 'bot'` and `COALESCE(role, '')` mean the same thing
    /// whichever shape arrived.
    private static func memberRole(_ tag: [String]) -> String? {
        for index in [3, 2] where tag.count > index && !tag[index].isEmpty {
            return tag[index]
        }
        return nil
    }

    /// Kind 39001: relay-authored owner/admin roster.
    private static func projectAdmins(_ event: NostrEvent, into db: Database) throws {
        guard let channelID = event.addressableIdentifier else { return }
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT source_created_at, source_event_id FROM channel_admin WHERE channel_id = ? LIMIT 1",
            arguments: [channelID]
        )
        if let existing {
            let appliedAt: Int64 = existing["source_created_at"]
            let appliedID: String = existing["source_event_id"]
            if (event.createdAt, event.id) <= (appliedAt, appliedID) { return }
        }

        try db.execute(sql: "DELETE FROM channel_admin WHERE channel_id = ?", arguments: [channelID])
        for tag in event.tags where tag.first == "p" && tag.count > 1 {
            try db.execute(
                sql: """
                INSERT INTO channel_admin
                    (channel_id, pubkey, role, source_created_at, source_event_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(channel_id, pubkey) DO UPDATE SET
                    role = excluded.role,
                    source_created_at = excluded.source_created_at,
                    source_event_id = excluded.source_event_id
                """,
                arguments: [
                    channelID,
                    tag[1],
                    tag.count > 2 ? tag[2] : "admin",
                    event.createdAt,
                    event.id,
                ]
            )
        }
    }

    // MARK: - Profiles

    /// Kind 0: profile metadata, replaceable per pubkey.
    ///
    /// The NIP-OA `auth` tag rides on this event and is verified here rather than at
    /// display time, because it is the one fact on a profile that grants standing: it is
    /// what makes a pubkey render as an agent. Verifying at the projection boundary means
    /// every reader inherits the check instead of each surface repeating it, and it
    /// matches both official clients, which verify the tag against the *profile event's
    /// author* so a forged or stale marker cannot turn a person into an agent
    /// (`desktop/src-tauri/src/nostr_convert.rs`, `mobile/lib/shared/crypto/nip_oa.dart`).
    ///
    /// Deliberately not the kind-10100 agent directory: that event's job is
    /// `channel_add_policy`, any user may publish one for their own key, and it carries no
    /// attestation to check — so its existence is a claim, not a credential.
    private static func projectProfile(_ event: NostrEvent, into db: Database) throws {
        let meta = try? JSONDecoder().decode(ProfileMetadata.self, from: Data(event.content.utf8))

        try db.execute(
            sql: """
            INSERT INTO profile (pubkey, display_name, picture, about, nip05, lud16,
                                 oa_owner_pubkey, source_event_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(pubkey) DO UPDATE SET
                display_name = excluded.display_name,
                picture = excluded.picture,
                about = excluded.about,
                nip05 = excluded.nip05,
                lud16 = excluded.lud16,
                oa_owner_pubkey = excluded.oa_owner_pubkey,
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
                NIPOA.verifiedOwnerPubkey(of: event)?.lowercased(),
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
    ///
    /// The tallies are parsed here, once per overlay received, rather than read out of
    /// the payload at query time — the timeline asks this question for every message on
    /// every screen, and a JSON parse per row per read is a cost paid forever for an
    /// answer that only changes when a new overlay arrives.
    ///
    /// Latest-wins is what makes a *withdrawn* reply come back down: the relay pushes a
    /// fresh overlay on a deletion as well as on an insert, and because that one is
    /// newer it replaces the count outright instead of being merged into a high-water
    /// mark. A summary that only ever grew would leave a thread whose replies were all
    /// removed still advertising them.
    ///
    /// An unparseable payload still stores — the blob is kept verbatim and the tally
    /// columns land NULL. That is the honest outcome: the store records what the relay
    /// said, and a summary this client cannot read contributes nothing to a count
    /// rather than contributing a zero (see ``ThreadSummaryPayload``).
    private static func projectThreadSummary(_ event: NostrEvent, into db: Database) throws {
        guard let root = event.addressableIdentifier else { return }
        let payload = ThreadSummaryPayload.decode(event.content)

        try db.execute(
            sql: """
            INSERT INTO thread_summary (
                root_id, event_id, payload, updated_at, descendant_count, last_reply_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(root_id) DO UPDATE SET
                event_id = excluded.event_id,
                payload = excluded.payload,
                updated_at = excluded.updated_at,
                descendant_count = excluded.descendant_count,
                last_reply_at = excluded.last_reply_at
            WHERE excluded.updated_at > thread_summary.updated_at
               OR (excluded.updated_at = thread_summary.updated_at
                   AND excluded.event_id > thread_summary.event_id)
            """,
            arguments: [
                root, event.id, event.content, event.createdAt,
                payload?.storedDescendantCount, payload?.storedLastReplyAt,
            ]
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
