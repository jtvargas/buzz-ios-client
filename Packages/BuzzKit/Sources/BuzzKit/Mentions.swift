import Foundation
import GRDB

/// One user a message mentions, resolved to a rendered name.
///
/// A query result, not a stored table: assembled on read by joining a message's
/// `p` tags (indexed in `event_tag`) to the `profile` projection. Unlike
/// ``MemberProfile``, ``displayName`` here is *non-optional* and already resolved
/// through the fallback, because a mention token has to render something inline
/// with no room for a placeholder — exactly the resolution
/// ``TimelineRow/displayName`` performs for a message author.
public struct MentionRef: Sendable, Hashable, Identifiable {
    /// The mentioned user's public key. The `p` tag's value, and the join key onto
    /// ``profile``.
    public let pubkey: String
    /// The name to render for the `@`-token: the profile's display name when it has
    /// a non-empty one, otherwise a short key form. Never empty.
    public let displayName: String

    /// Stable identity for a `ForEach` over a message's mentions.
    public var id: String { pubkey }

    public init(pubkey: String, displayName: String) {
        self.pubkey = pubkey
        self.displayName = displayName
    }
}

/// The ordered, de-duplicated list of users one message mentions.
///
/// A thin wrapper over `[MentionRef]` — the shape ``BuzzEventStore/mentions(for:)``
/// returns per message — conforming to `RandomAccessCollection` so a mention
/// renderer can `ForEach` it directly. Order follows the `p` tags' authored
/// position, so the tokens render in the order they were tagged; a pubkey tagged
/// more than once appears once, at its first position.
public struct MentionRefList: Sendable, Hashable, RandomAccessCollection {
    /// The mentions, in authored order, de-duplicated by pubkey.
    public let refs: [MentionRef]

    public init(_ refs: [MentionRef]) {
        self.refs = refs
    }

    public var startIndex: Int { refs.startIndex }
    public var endIndex: Int { refs.endIndex }
    public subscript(position: Int) -> MentionRef { refs[position] }
}

public extension BuzzEventStore {
    /// The mentioned users of each of `ids`, keyed by the mentioning message's event
    /// id, for rendering `@`-tokens on any surface.
    ///
    /// A message with no mentions is simply absent from the result — the caller
    /// treats a missing key as "no mentions" — so the dictionary carries only what
    /// there is to render, exactly like ``reactions(for:selfPubkey:)``. An empty
    /// `ids` returns `[:]` without touching the database.
    ///
    /// Each mention's ``MentionRef/displayName`` is resolved the same way
    /// ``TimelineRow/displayName`` resolves an author's: the profile's display name
    /// when it has a non-empty one, otherwise the first eight characters of the key.
    /// A pubkey a message tags more than once yields a single ref, at its first `p`
    /// tag's position.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the
    /// actor, and so `ValueObservation` can track the `event_tag` and `profile`
    /// tables it reads — the same discipline as the timeline and reaction reads, so
    /// a mention's rendered name updates live when the mentioned user's profile
    /// lands.
    nonisolated func mentions(for ids: [String]) throws -> [String: MentionRefList] {
        guard !ids.isEmpty else { return [:] }
        return try reader.read { db in
            try Self.fetchMentions(db, ids: ids)
        }
    }
}

extension BuzzEventStore {
    /// The `p`-tag-to-profile join, over an open database so an observation can
    /// track it.
    ///
    /// Ordered by `(event_id, position)` so each message's mentions come back in
    /// authored order and the per-message de-dup keeps the first occurrence. The
    /// fallback name is computed in Swift, not via SQL `COALESCE`, because it must
    /// also replace an *empty* profile name — the `!isEmpty` guard
    /// ``TimelineRow/displayName`` applies, which a NULL-only `COALESCE` would miss.
    static func fetchMentions(_ db: Database, ids: [String]) throws -> [String: MentionRefList] {
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        var placeholders: [String] = []
        for (index, id) in ids.enumerated() {
            let key = "e\(index)"
            placeholders.append(":\(key)")
            arguments[key] = id
        }

        let sql = """
        SELECT et.event_id     AS event_id,
               et.value        AS pubkey,
               p.display_name  AS display_name
        FROM event_tag et
        LEFT JOIN profile p ON p.pubkey = et.value
        WHERE et.name = 'p'
          AND et.event_id IN (\(placeholders.joined(separator: ", ")))
        ORDER BY et.event_id ASC, et.position ASC
        """

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        var result: [String: [MentionRef]] = [:]
        var seen: [String: Set<String>] = [:]
        for row in rows {
            let eventID: String = row["event_id"]
            let pubkey: String = row["pubkey"]
            // A pubkey tagged twice on one message yields one ref, at its first
            // position — the ORDER BY already put that occurrence first.
            if seen[eventID, default: []].contains(pubkey) { continue }
            seen[eventID, default: []].insert(pubkey)

            let name = resolvedMentionName(displayName: row["display_name"], pubkey: pubkey)
            result[eventID, default: []].append(MentionRef(pubkey: pubkey, displayName: name))
        }
        return result.mapValues(MentionRefList.init)
    }

    /// The mention display name, resolved exactly as ``TimelineRow/displayName``
    /// resolves an author's: a non-empty profile name, else the first eight
    /// characters of the key.
    private static func resolvedMentionName(displayName: String?, pubkey: String) -> String {
        if let displayName, !displayName.isEmpty { return displayName }
        return String(pubkey.prefix(8))
    }
}
