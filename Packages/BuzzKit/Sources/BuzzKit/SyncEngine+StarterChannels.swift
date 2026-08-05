import Foundation
import GRDB

/// The starter channels a community is expected to have, and the two things this client
/// does about them on every authoritative directory pass: join them once, and keep their
/// replies fetched.
///
/// # Why the client does this at all
///
/// Desktop creates `general` and `welcome-everyone` when it creates a community
/// (`desktop/src-tauri/src/commands/channels.rs`), and until now every client *saw* them
/// regardless — the relay serves every open channel to any key, so a reader who had never
/// joined anything still had them in the sidebar. Scoping the sidebar and the live
/// subscriptions to real membership takes that away from anyone whose roster row was never
/// written, which on a relay in use is nearly everyone. So membership in the starter set
/// has to become a thing this client establishes rather than something it assumed.
///
/// # Why it runs on every launch and not only on a fresh community join
///
/// An install that already exists never joins a community again, so a join-time hook would
/// reach exactly the identities that do not need it and none of the ones that do. The gate
/// is therefore a per-identity ``BuzzEventStore/hasSeededStarterChannels(identity:)`` mark
/// consulted on each directory pass — one local read on the overwhelmingly common path,
/// and correct for an install that predates this code.
extension SyncEngine {
    /// The names, in the order they are joined. Names rather than ids because a channel id
    /// is a per-community UUID minted by whoever created it, so there is nothing stable to
    /// hard-code; the relay's own bootstrap is what makes the *names* the contract.
    static let starterChannelNames = ["general", "welcome-everyone"]

    /// Joins the starter channels once per identity, then keeps their replies fetched.
    ///
    /// Runs at the end of the authoritative pass, after every channel's head window has
    /// been reconciled and the outbox drained, because both halves depend on that having
    /// happened and neither is worth putting in front of it.
    func settleStarterChannels(joined: Set<String>, generation: Int) async {
        guard let identity = selfPubkeyHex else { return }
        let starters = (try? await store.starterChannelIDs(
            named: Self.starterChannelNames
        )) ?? []
        // Nothing to seed and nothing to prefetch: this relay has not published the
        // starter set yet. Deliberately *not* recorded as seeded — a community that
        // creates them later still gets them, at the cost of one local query per pass.
        guard !starters.isEmpty else { return }

        await seedStarterMembership(starters, joined: joined, identity: identity, generation: generation)
        guard isCurrent(generation) else { return }
        await prefetchStarterThreads(starters, generation: generation)
    }

    /// Publishes a join for each starter channel this identity is not already on the roster
    /// of, then records the identity as seeded.
    ///
    /// # What "seeded" is allowed to mean
    ///
    /// Recorded once every starter has reached a *verdict*, not once every one succeeded.
    /// A ``ChannelJoinError/rejected(_:)`` is terminal by the relay's own contract — the
    /// same request earns the same answer — so retrying it on every launch would be a
    /// publish per pass forever against a channel that will never take it. A
    /// ``ChannelJoinError/publishFailed(_:)`` reached no verdict, so the mark is withheld
    /// and the next pass tries again.
    ///
    /// An identity already on both rosters — anyone who was here before this client scoped
    /// itself to membership — publishes nothing at all and is marked immediately.
    private func seedStarterMembership(
        _ starters: [String],
        joined: Set<String>,
        identity: String,
        generation: Int
    ) async {
        guard (try? await store.hasSeededStarterChannels(identity: identity)) == false else { return }

        var reachedVerdict = true
        for channel in starters where !joined.contains(channel) {
            guard isCurrent(generation) else { return }
            do {
                try await joinChannel(channel)
            } catch ChannelJoinError.rejected {
                // Terminal. Counted as answered so the seeding stops asking.
            } catch {
                reachedVerdict = false
            }
        }
        guard reachedVerdict else { return }
        try? await store.recordStarterChannelsSeeded(identity: identity)
    }

    /// Fetches the newest replies in each starter channel, so the channels the reader
    /// actually opens have their threads populated before they open one.
    ///
    /// # Why per channel, when a global pass now runs behind it
    ///
    /// ``SyncEngine/settleThreadPrefetch(generation:)`` covers every channel, including
    /// these two, so this could be deleted — but it would take a guarantee with it. One
    /// global pass takes the twenty most recently active threads across *every* channel, so
    /// on an account in many channels two busy ones can consume it and the starter channels
    /// get whatever the loop reaches on a later pass, if it reaches that far. Asking per
    /// channel first gives each of these its own budget outright, which is what a reader
    /// arriving in a new community sees first. The cost once they are settled is two local
    /// queries that return nothing.
    ///
    /// # Why it needs no gate of its own
    ///
    /// A fetched thread stops being a candidate until it gains new activity
    /// (``BuzzEventStore/recordThreadPrefetch(root:summaryEventID:)``), so the second pass
    /// costs one local query returning nothing and the work is proportional to what has
    /// changed. That converges on its own, which is better than a once-per-launch flag —
    /// a flag would also have to be got right on resume, and a missed pass would be a
    /// screen with no replies in it.
    private func prefetchStarterThreads(_ starters: [String], generation: Int) async {
        for channel in starters {
            guard isCurrent(generation) else { return }
            await prefetchThreads(in: channel)
        }
    }
}

// MARK: - Store

extension BuzzEventStore {
    /// The meta gate for ``SyncEngine/settleStarterChannels(joined:generation:)``, keyed
    /// per identity for the same reason `channel_access_seeded:` is: two identities on one
    /// device have separate rosters and one having been seeded says nothing about the other.
    private static func starterChannelsSeededKey(_ identity: String) -> String {
        "starter_channels_seeded:\(identity)"
    }

    func hasSeededStarterChannels(identity: String) async throws -> Bool {
        try await reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Self.starterChannelsSeededKey(identity)]
            ) != nil
        }
    }

    func recordStarterChannelsSeeded(identity: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO meta (key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = '1'
                """,
                arguments: [Self.starterChannelsSeededKey(identity)]
            )
        }
    }

    /// Resolves starter channel *names* to the ids this relay holds for them, in the order
    /// asked, skipping any name it has nothing for.
    ///
    /// # Why one query per name, and why the widest roster wins
    ///
    /// A name is not unique — a relay that has hosted more than one community holds more
    /// than one `general`, and this device's projection holds every one it can see. There
    /// is no `created_at` on the channel projection to prefer the oldest by, so the tie is
    /// broken by roster size: the `general` the community is actually in is the one with
    /// the members in it. Ordered by id after that, so two equally-populated channels
    /// resolve to the same one on every launch and on every device rather than to whichever
    /// SQLite happened to return first.
    ///
    /// Archived and private channels are excluded because neither can be self-joined: the
    /// relay refuses an archived channel with `invalid:` and a private one with
    /// `restricted:`. Excluding them here means the seeding never publishes a request it
    /// knows the answer to, and falls through to the next-best channel of that name.
    func starterChannelIDs(named names: [String]) async throws -> [String] {
        try await reader.read { db in
            try names.compactMap { name in
                try String.fetchOne(db, sql: """
                SELECT c.id
                  FROM channel c
                  LEFT JOIN channel_member cm ON cm.channel_id = c.id
                 WHERE c.name = ? COLLATE NOCASE
                   AND c.is_archived = 0
                   AND c.is_private = 0
                   AND (c.channel_type IS NULL OR c.channel_type <> 'dm')
                 GROUP BY c.id
                 ORDER BY COUNT(cm.pubkey) DESC, c.id ASC
                 LIMIT 1
                """, arguments: [name])
            }
        }
    }
}
