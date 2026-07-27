import Foundation
import GRDB
import NostrCore

/// Who the local identity has `@`-mentioned lately, most recent first.
///
/// The composer's ranking signal for "recent usage": a person you named a minute ago is
/// far likelier to be the one you are naming now than whoever happens to sort first
/// alphabetically.
///
/// A query result, not a stored table, and deliberately not a local preference file
/// either. The `p` tags on your own sent messages *are* the record of who you have
/// mentioned — ``OutboundTags`` emits one only for an explicit `@` token and never for a
/// thread parent — so deriving it from the log means a fresh install inherits the order
/// the moment history syncs, and no second list can fall out of step with what was
/// actually sent.
public struct RecentMentions: Sendable, Hashable {
    /// The mentioned pubkeys, lowercased, newest mention first, de-duplicated.
    public let pubkeys: [String]
    /// `pubkeys` inverted, so the composer's ranking is a dictionary lookup per
    /// candidate rather than a linear scan per keystroke.
    private let ranks: [String: Int]

    /// Nobody has been mentioned — a fresh install, or an identity-less session.
    public static let empty = RecentMentions([])

    public init(_ pubkeys: [String]) {
        self.pubkeys = pubkeys
        ranks = Dictionary(
            pubkeys.enumerated().map { ($1, $0) },
            // First occurrence wins. The caller already de-duplicates, so this only
            // ever settles a list built by hand in a test.
            uniquingKeysWith: { first, _ in first }
        )
    }

    public var isEmpty: Bool { pubkeys.isEmpty }

    /// How recently this identity was mentioned — `0` for the most recent — or `nil`
    /// for someone who has never been mentioned.
    ///
    /// Case-insensitive, because a pubkey reaches this from three places (a `p` tag as
    /// some other client wrote it, a channel roster, an agent directory) and only one
    /// of them is normalized.
    public func rank(of pubkey: String) -> Int? { ranks[pubkey.lowercased()] }
}

public extension BuzzEventStore {
    /// The identities `selfPubkey` has mentioned most recently, newest first.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the actor,
    /// and so `ValueObservation` can track the `event`, `event_tag`, and `outbox` tables
    /// it reads — the same discipline behind ``mentionCandidates(channel:selfPubkey:)``,
    /// so the composer's ranking updates from the same signal its candidate list does.
    ///
    /// Global rather than per-channel on purpose: "who I mention" is a fact about a
    /// person's habits, not about the room they are standing in. It costs nothing to
    /// keep it global, because the candidate index it ranks is already scoped to the
    /// channel — someone you mentioned elsewhere who is not a candidate here is simply
    /// not in the list to be ranked.
    ///
    /// Pending sends count. Their `p` tags are the mentions you made *most* recently, and
    /// a relay round trip is exactly the window in which you compose the next message.
    ///
    /// - Parameters:
    ///   - selfPubkey: the local identity. `nil` or empty yields ``RecentMentions/empty``
    ///     — with no identity there is no "my mentions" to read, and the alternative
    ///     (every author's mentions) would rank by a stranger's habits.
    ///   - limit: how many identities to keep. No default: the number belongs to the
    ///     surface that decides how deep its ranking reaches, and a value chosen here
    ///     would be a second place that decision lived.
    nonisolated func recentMentions(by selfPubkey: String?, limit: Int) throws -> RecentMentions {
        guard let selfPubkey, !selfPubkey.isEmpty, limit > 0 else { return .empty }
        // Normalized here so the reads below can compare `event.pubkey` with plain `=`.
        // A stored pubkey is always lowercase — NIP-01 hex is lowercase and
        // ``NostrCore/Hex`` decodes strictly, so an event carrying any other spelling
        // never reaches the log — and every other query in BuzzKit already relies on
        // that. Doing it in SQL instead (`COLLATE NOCASE`) is what makes the comparison
        // unable to use an index; see ``fetchRecentMentions``.
        let identity = selfPubkey.lowercased()
        return try reader.read { db in
            try Self.fetchRecentMentions(db, selfPubkey: identity, limit: limit)
        }
    }
}

extension BuzzEventStore {
    /// The recent-mention read, over an open database so an observation can track it.
    ///
    /// Two sources merged on the mention's own timestamp rather than concatenated: a
    /// *failed* outbox row can be older than anything in the log, so putting pending
    /// sends unconditionally first would let a message that never left the device
    /// outrank one that did.
    static func fetchRecentMentions(
        _ db: Database,
        selfPubkey: String,
        limit: Int
    ) throws -> RecentMentions {
        var newest: [String: Int64] = [:]
        for (pubkey, mentionedAt) in try loggedMentions(db, selfPubkey: selfPubkey, limit: limit)
            + pendingMentions(db, selfPubkey: selfPubkey) {
            newest[pubkey] = max(newest[pubkey] ?? .min, mentionedAt)
        }

        // Newest first, ties broken by key so the order is total — two mentions written
        // in the same second must not reshuffle the panel between keystrokes.
        let ordered = newest.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }
        return RecentMentions(ordered.prefix(limit).map(\.key))
    }

    /// The `p` tags on the identity's own sent channel messages, keyed by the newest
    /// message that carries each.
    ///
    /// Kind-scoped to channel messages, which is what excludes the `p` tag on a direct
    /// message's own creation event — that names the *recipient* of a conversation, not
    /// someone the author mentioned, and counting it would rank every DM peer above the
    /// people actually being `@`-named.
    ///
    /// # Why `CROSS JOIN`, and why the schema carries `event_author`
    ///
    /// Left to itself SQLite drives this from `event_tag_lookup (name = 'p')` — every
    /// mention *anyone* ever wrote — and throws away all but the author's own. It has no
    /// statistics saying "one identity's messages" is the narrower set, and this read
    /// re-runs on every committed transaction. Measured over a 50k-event store with 17k
    /// mentions: **63 ms** that way, **2 ms** driven from `event`.
    ///
    /// `CROSS JOIN` is how SQLite is told to keep the written order (it disables join
    /// reordering for that one join and nothing else, and does not change the result —
    /// verified equal). `INDEXED BY` is *not* the tool here: it forces the index without
    /// forcing the order, which left the same outer table and made the read 8.4 s.
    ///
    /// The binary `=` on `e.pubkey` is load-bearing for the same reason. `COLLATE NOCASE`
    /// there cannot use `event_author`, so it costs the whole win even with the join
    /// order pinned; the caller lowercases instead, which is sound because a stored
    /// pubkey is always lowercase hex.
    private static func loggedMentions(
        _ db: Database,
        selfPubkey: String,
        limit: Int
    ) throws -> [(String, Int64)] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT et.value          AS pubkey,
               MAX(e.created_at) AS mentioned_at
        FROM event e
        CROSS JOIN event_tag et ON et.event_id = e.id AND et.name = 'p'
        WHERE e.kind = :kind
          AND e.pubkey = :selfPubkey
        GROUP BY et.value
        ORDER BY mentioned_at DESC, pubkey ASC
        LIMIT :limit
        """, arguments: [
            "kind": EventKind.channelMessage.rawValue,
            "selfPubkey": selfPubkey,
            "limit": limit,
        ])
        return rows.map { row in
            let pubkey: String = row["pubkey"]
            return (pubkey.lowercased(), row["mentioned_at"] ?? Int64(0))
        }
    }

    /// The same tags on messages signed but not yet acknowledged by the relay.
    ///
    /// Read from the row's `tags` JSON in Swift rather than in SQL: the outbox
    /// denormalizes the columns the timeline union needs and nothing else, and the tag
    /// index only ever holds *ingested* events. Bounded by ``pendingMentionScan`` so a
    /// long offline queue cannot turn a per-commit read into a full table decode.
    private static func pendingMentions(
        _ db: Database,
        selfPubkey: String
    ) throws -> [(String, Int64)] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT tags, created_at
        FROM outbox
        WHERE kind = :kind
          AND pubkey = :selfPubkey
        ORDER BY created_at DESC, event_id DESC
        LIMIT :scan
        """, arguments: [
            "kind": EventKind.channelMessage.rawValue,
            "selfPubkey": selfPubkey,
            "scan": pendingMentionScan,
        ])

        return rows.flatMap { row -> [(String, Int64)] in
            let json: String = row["tags"]
            let createdAt: Int64 = row["created_at"] ?? 0
            let tags = (try? JSONDecoder().decode([[String]].self, from: Data(json.utf8))) ?? []
            return tags.compactMap { tag in
                guard tag.count > 1, tag[0] == "p" else { return nil }
                return (tag[1].lowercased(), createdAt)
            }
        }
    }

    /// How far back into the pending queue the recency read looks. Generous next to any
    /// real backlog of unsent messages, and small enough that decoding their tags stays
    /// off the frame budget.
    private static let pendingMentionScan = 50
}
