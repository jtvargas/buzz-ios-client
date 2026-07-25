import Foundation
import GRDB
import NostrCore

/// One emoji's tally on a message: how many distinct members reacted with it,
/// whether the local identity is among them, and — when it is — the id of that
/// reaction so the UI can withdraw it.
///
/// Like ``TimelineRow`` this is a query result, not a stored table. Reactions live
/// in the append-only log and their `reaction` projection; this shape is assembled
/// on read, applying the *same* read-time deletion authority the timeline applies,
/// so a withdrawn reaction (its author's kind-5) drops out without any tally column
/// anyone has to keep in step. That is what lets a single `ValueObservation` keep
/// the chips live.
public struct ReactionGroup: Sendable, Hashable, Identifiable {
    /// The rendered emoji. Bare `+`/empty NIP-25 likes were normalised to a heart
    /// by the projector, so this is always something displayable.
    public let emoji: String
    /// How many distinct members reacted with this emoji, counting each member
    /// once however many reaction events they authored.
    public let count: Int
    /// Whether the local identity has a surviving reaction with this emoji.
    public let reactedBySelf: Bool
    /// The local identity's surviving reaction event id for this emoji, or `nil`
    /// when it did not react. Carried so a tap on an own, highlighted chip can
    /// withdraw exactly that reaction (a kind-5 naming this id) rather than having
    /// to re-query for it.
    public let selfReactionID: String?

    /// Stable across re-reads so a `ForEach` animates a chip's count in place
    /// instead of tearing it down and rebuilding it.
    public var id: String { emoji }

    public init(emoji: String, count: Int, reactedBySelf: Bool, selfReactionID: String?) {
        self.emoji = emoji
        self.count = count
        self.reactedBySelf = reactedBySelf
        self.selfReactionID = selfReactionID
    }
}

public extension BuzzEventStore {
    /// The surviving reaction groups for each of `targetIDs`, keyed by target id.
    ///
    /// A target with no surviving reactions is simply absent from the result — the
    /// caller treats a missing key as "no reactions" — so the dictionary carries
    /// only what there is to render.
    ///
    /// Withdrawn reactions are excluded through the *same* read-time predicate the
    /// timeline uses for message deletions (``deletionApplies(target:author:owner:)``):
    /// a reaction renders withdrawn when a kind-5 from its own author (or that
    /// author's verified NIP-OA owner), or a relay kind-9005 tombstone, names it.
    /// This mirrors the projector's rule that it records deletions without judging
    /// them; the judgment lands here.
    ///
    /// The spec's minimal shape was `reactions(for:) -> [String: [ReactionGroup]]`;
    /// `selfPubkey` is added because ``ReactionGroup/reactedBySelf`` cannot be
    /// computed without the local identity. Pass `nil` when it is unknown (the same
    /// keyless degradation presence uses) and no chip is highlighted.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the
    /// actor, and so `ValueObservation` can track the `reaction`, `deletion`, and
    /// `event_owner` tables it reads — the discipline that lets the chips update
    /// live alongside the timeline.
    nonisolated func reactions(
        for targetIDs: [String],
        selfPubkey: String?
    ) throws -> [String: [ReactionGroup]] {
        guard !targetIDs.isEmpty else { return [:] }
        return try reader.read { db in
            try Self.fetchReactions(db, targetIDs: targetIDs, selfPubkey: selfPubkey)
        }
    }
}

extension BuzzEventStore {
    /// The reaction-aggregation query, over an open database so an observation can
    /// track it.
    ///
    /// Counts distinct reactors per `(target, emoji)` rather than raw events, so a
    /// member who reacted twice with the same emoji counts once — the tally means
    /// "how many people", which is what a chip communicates. Ordered oldest-emoji
    /// first (by the earliest surviving reaction), then emoji, so chip order is
    /// stable across re-reads instead of shuffling when a new reaction lands.
    static func fetchReactions(
        _ db: Database,
        targetIDs: [String],
        selfPubkey: String?
    ) throws -> [String: [ReactionGroup]] {
        // Named placeholders for the IN list, so the whole statement stays named
        // (GRDB forbids mixing named `:self` with positional `?`).
        var arguments: [String: (any DatabaseValueConvertible)?] = ["self": selfPubkey]
        var placeholders: [String] = []
        for (index, id) in targetIDs.enumerated() {
            let key = "t\(index)"
            placeholders.append(":\(key)")
            arguments[key] = id
        }

        let deletionWithdrew = deletionApplies(
            target: "r.event_id",
            author: "r.pubkey",
            owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = r.event_id)"
        )

        let sql = """
        SELECT r.target_id AS target_id,
               r.emoji     AS emoji,
               COUNT(DISTINCT r.pubkey) AS reactor_count,
               MAX(CASE WHEN r.pubkey = :self THEN 1 ELSE 0 END) AS reacted_by_self,
               MAX(CASE WHEN r.pubkey = :self THEN r.event_id END) AS self_reaction_id,
               MIN(r.created_at) AS first_at
        FROM reaction r
        WHERE r.target_id IN (\(placeholders.joined(separator: ", ")))
          AND NOT \(deletionWithdrew)
        GROUP BY r.target_id, r.emoji
        ORDER BY r.target_id ASC, first_at ASC, r.emoji ASC
        """

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        var result: [String: [ReactionGroup]] = [:]
        for row in rows {
            let target: String = row["target_id"]
            let group = ReactionGroup(
                emoji: row["emoji"],
                count: row["reactor_count"] ?? 0,
                reactedBySelf: (row["reacted_by_self"] ?? 0) != 0,
                selfReactionID: row["self_reaction_id"]
            )
            result[target, default: []].append(group)
        }
        return result
    }
}
