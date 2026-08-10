import Foundation
import GRDB
import NostrCore

/// One emoji's reactors on a message: who reacted, in the order they did.
///
/// The companion to ``ReactionGroup``, which answers *how many* — this answers *which
/// people*. Both are query results assembled on read from the same `reaction` projection
/// through the same withdrawal predicate, so a chip reading `3` and the list behind it
/// naming three people cannot disagree: there is no second tally to keep in step.
///
/// Pubkeys rather than a joined profile shape, deliberately. The reactor list is drawn
/// through the app's shared name directory — the one the timeline and the channel people
/// list draw through — so somebody reads identically in all three. Joining here would be a
/// second source for a name that already has one, and it would drop a reactor whose
/// profile has not arrived or who reacted and then left the channel. Both belong in the
/// list.
public struct ReactionReactorGroup: Sendable, Hashable, Identifiable {
    /// The rendered emoji, exactly as ``ReactionGroup/emoji`` carries it.
    public let emoji: String
    /// The members who reacted with it, oldest reaction first, each member once however
    /// many reaction events they authored.
    public let reactors: [String]

    /// Stable across re-reads so a `ForEach` keeps a page in place as a reactor lands.
    public var id: String { emoji }

    /// The same number ``ReactionGroup/count`` carries, by construction rather than by
    /// agreement — both are the count of distinct surviving reactors.
    public var count: Int { reactors.count }

    public init(emoji: String, reactors: [String]) {
        self.emoji = emoji
        self.reactors = reactors
    }
}

public extension BuzzEventStore {
    /// Who reacted to `targetID`, grouped by emoji in the same order the chips are drawn
    /// in: oldest emoji first, by its earliest surviving reaction.
    ///
    /// An emoji with no surviving reactor is absent rather than present-and-empty, the
    /// same shape ``reactions(for:selfPubkey:)`` returns.
    ///
    /// Synchronous and `nonisolated` for the reason the chips query is: it runs on the
    /// concurrent reader off the actor, and a `ValueObservation` can track the `reaction`,
    /// `deletion`, `event_owner` and `outbox` tables it reads — which is what lets an open
    /// sheet update as a reaction lands under it.
    nonisolated func reactors(
        for targetID: String,
        selfPubkey: String?
    ) throws -> [ReactionReactorGroup] {
        try reader.read { db in
            try Self.fetchReactors(db, targetID: targetID, selfPubkey: selfPubkey)
        }
    }
}

extension BuzzEventStore {
    /// The reactor query, over an open database so an observation can track it.
    static func fetchReactors(
        _ db: Database,
        targetID: String,
        selfPubkey: String?
    ) throws -> [ReactionReactorGroup] {
        let deletionWithdrew = deletionApplies(
            target: "r.event_id",
            author: "r.pubkey",
            owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = r.event_id)"
        )

        // Grouped by (emoji, member) rather than by emoji alone: the row per member is
        // what makes a member who reacted twice with one emoji a single name, and
        // `MIN(created_at)` is what orders them by when they first did. Ordering the whole
        // result by that same value is what makes the *emoji* come out in chip order — the
        // first row carrying an emoji is its earliest reaction.
        //
        // `self_reaction_id` is picked with the same `MAX` the chips query uses, so the id
        // matched against a queued withdrawal below is the id the chip would have named
        // when it queued one.
        let sql = """
        SELECT r.emoji AS emoji,
               r.pubkey AS pubkey,
               MIN(r.created_at) AS first_at,
               MAX(CASE WHEN r.pubkey = :self THEN r.event_id END) AS self_reaction_id
        FROM reaction r
        WHERE r.target_id = :target
          AND NOT \(deletionWithdrew)
        GROUP BY r.emoji, r.pubkey
        ORDER BY first_at ASC, r.pubkey ASC
        """

        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: ["target": targetID, "self": selfPubkey]
        )

        var accumulated = Accumulator()
        for row in rows {
            let emoji: String = row["emoji"]
            if accumulated.reactors[emoji] == nil { accumulated.order.append(emoji) }
            accumulated.reactors[emoji, default: []].append(row["pubkey"])
            if let reactionID: String = row["self_reaction_id"] {
                accumulated.selfReactionIDs[reactionID] = emoji
            }
        }

        // The same optimistic layer the chips carry, narrowed to the only reactor a queued
        // event can be about — the local identity. Without it a reader taps a chip,
        // watches the count go up, holds it, and does not find themselves in the list they
        // were just added to.
        if let selfPubkey {
            try applyOptimisticReactors(
                db,
                into: &accumulated,
                targetID: targetID,
                selfPubkey: selfPubkey
            )
        }
        return accumulated.groups
    }

    /// The reactor lists mid-assembly: who reacted with what, the emoji order the rows
    /// arrived in, and where the local identity's own reactions sit.
    ///
    /// One value rather than three collections passed around together, because the
    /// optimistic layer has to touch all three and keeping them in step at four call sites
    /// is how the emoji order and the lists start disagreeing.
    struct Accumulator {
        /// Emoji in chip order — oldest reaction first.
        var order: [String] = []
        /// Reactors per emoji, oldest first.
        var reactors: [String: [String]] = [:]
        /// Which emoji each of the local identity's surviving reaction ids belongs to, so
        /// a queued withdrawal naming one can find the list to take them out of.
        var selfReactionIDs: [String: String] = [:]

        /// The finished groups. An emoji whose last reactor was withdrawn keeps its place
        /// in ``order`` and is dropped here, so nothing has to prune two collections.
        var groups: [ReactionReactorGroup] {
            order.compactMap { emoji in
                guard let people = reactors[emoji], !people.isEmpty else { return nil }
                return ReactionReactorGroup(emoji: emoji, reactors: people)
            }
        }
    }

    /// Folds the local identity's queued reactions and withdrawals into the reactor lists.
    ///
    /// Withdrawals first, then additions, matching
    /// ``mergeOptimistic(into:additions:withdrawnReactionIDs:)``: a queued reaction that
    /// its own queued withdrawal also names nets to nothing.
    private static func applyOptimisticReactors(
        _ db: Database,
        into accumulated: inout Accumulator,
        targetID: String,
        selfPubkey: String
    ) throws {
        let pending = try optimisticOwnReactions(
            db,
            targetIDs: [targetID],
            selfPubkey: selfPubkey
        )

        for reactionID in pending.withdrawnReactionIDs {
            guard let emoji = accumulated.selfReactionIDs[reactionID] else { continue }
            accumulated.reactors[emoji]?.removeAll { $0 == selfPubkey }
        }

        for addition in pending.additions[targetID] ?? []
            where !pending.withdrawnReactionIDs.contains(addition.eventID) {
            var people = accumulated.reactors[addition.emoji] ?? []
            guard !people.contains(selfPubkey) else { continue }
            // Appended, not inserted: a reaction just sent is the newest one, which is
            // where the ordering above will put it once the relay echoes it back. A
            // brand-new emoji sorts to the end of the strip for the same reason — the
            // rule ``mergeOptimistic(into:additions:withdrawnReactionIDs:)`` applies to
            // the newest chip.
            people.append(selfPubkey)
            if accumulated.reactors[addition.emoji] == nil {
                accumulated.order.append(addition.emoji)
            }
            accumulated.reactors[addition.emoji] = people
        }
    }
}
