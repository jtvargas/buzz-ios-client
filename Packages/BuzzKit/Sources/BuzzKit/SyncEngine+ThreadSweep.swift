import Foundation
import NostrCore

extension SyncEngine {
    /// Asks the relay directly about the threads this device holds, without consulting the
    /// relay's own tally about whether it needs to.
    ///
    /// # The half of the defect the launch prefetch cannot reach
    ///
    /// ``settleThreadPrefetch(generation:)`` fetches bodies for threads the tally says are
    /// behind. Its candidate test is `last_reply_at > local MAX(created_at)`, and that test
    /// is unanswerable for a root that has fallen behind the sync watermark: the channel
    /// window pages down from head and stops there, ordered by each root's own immutable
    /// `created_at`, so an old root is never re-paged and never carries a fresh kind:39005.
    /// A reply landing on it while the phone is asleep raises `last_reply_at` on the relay
    /// and nothing here ever learns it. The thread is not a candidate, so the prefetch skips
    /// exactly the threads that need it — no dot, no Activity row, no mention badge, because
    /// every one of those surfaces is computed from the local log.
    ///
    /// So this pass distrusts the tally by not reading it. Candidacy is local — roots held,
    /// in joined channels, inside ``SyncEngineConfig/threadSweepHorizon`` — and each ask
    /// carries `since` = the newest reply held for that thread, so a thread that has not
    /// changed answers with nothing rather than with its history.
    ///
    /// # The brake, and why it is the socket rather than a clock
    ///
    /// A candidate set built from "roots that exist" does not shrink as it is served, so
    /// this needs a brake or it re-asks forever — four requests on every authoritative pass
    /// on a device that is entirely caught up, where the prefetch in front of it costs one
    /// local query and nothing on the wire.
    ///
    /// The brake is: *skip a root already swept on this socket*. `reconcileAuthoritativeChannels`
    /// runs on foreground, membership change, CLOSED recovery and pull-refresh as well as
    /// launch, and all of those share a socket, so the second and later passes of a session
    /// cost **zero requests** once the horizon is covered — the same convergence the
    /// prefetch has. A *fresh* socket re-arms the whole sweep, which is the right trigger
    /// rather than an arbitrary interval: a new socket is precisely the evidence that this
    /// device was away and may have missed a reply. It is also already the app's most
    /// expensive moment by a wide margin — `.ready` clears every channel's sync state, so
    /// the reconcile ahead of this one re-pages sixteen head windows. Four more requests
    /// behind that is noise.
    ///
    /// A clock-interval brake was the alternative and is worse where it counts: it would
    /// leave a reply that landed during the gap undiscovered until the interval expired,
    /// which is latency on the exact case this exists for.
    ///
    /// # Why one pass, not a loop
    ///
    /// The prefetch loops because its candidates *drain* — each pass permanently removes
    /// what it fetched, so looping terminates on an empty query. These candidates only
    /// become ineligible, and there can be hundreds of them, so a loop here would page the
    /// whole horizon on a single launch. One capful per pass, ordered least-recently-swept
    /// first, spreads that across the passes a session makes anyway and keeps the cost of
    /// any one launch flat.
    ///
    /// # Why it runs after the prefetch
    ///
    /// Running this first would restore nothing on its own: it repairs *bodies*, and so does
    /// the prefetch, but the prefetch is the cheaper and better-targeted of the two and its
    /// candidates are the threads with known-fresh activity. Ordering it first spends the
    /// launch on what is known to be stale before spending it on what might be.
    func settleThreadSweep(generation: Int) async {
        guard let identity = selfPubkeyHex else { return }

        let now = Int64(now().timeIntervalSince1970)
        // Derived from the ready generation rather than recorded by the connection state
        // machine: the generation already changes exactly when the socket does, so this
        // needs no new hook and cannot drift from what `isCurrent(generation)` means.
        if sweepEpoch?.generation != generation {
            sweepEpoch = (generation: generation, startedAt: now)
        }
        let staleBefore = sweepEpoch?.startedAt ?? now

        let candidates = (try? store.threadSweepCandidates(
            identity: identity,
            horizon: now - Int64(config.threadSweepHorizon),
            staleBefore: staleBefore,
            limit: config.threadSweepRootLimit
        )) ?? []
        guard !candidates.isEmpty else { return }

        let replyLimit = config.threadPrefetchReplyLimit
        for batch in candidates.batched(by: Self.maxFiltersPerRequest) {
            guard isCurrent(generation) else { return }

            // One filter per thread, for the reason the prefetch spells out in full: a
            // single filter carrying every root ORs them under one global limit, so the
            // busiest thread eats the budget and the rest come back empty — which reads
            // exactly like the bug being fixed. `since` is per filter, which is the whole
            // reason this can afford to ask about forty threads it has no evidence about.
            let filters = batch.map {
                Filter(
                    kinds: [.channelMessage],
                    since: $0.since,
                    limit: replyLimit,
                    tagQueries: ["e": [$0.rootID]]
                )
            }
            guard let events = try? await subscriptions.query(filters),
                  (try? await store.ingest(batch: events, phase: .backfill)) != nil
            else {
                // A dropped socket or a failed write. Nothing is recorded for this batch, so
                // these roots stay top of the ordering and the next pass starts here.
                return
            }

            // Recorded whatever came back, including nothing at all — an empty answer is the
            // common and desirable case and is exactly what the record is for.
            try? await store.recordThreadSweep(roots: batch.map(\.rootID), at: now)
        }
    }
}

private extension Array {
    /// The array in order, in runs of at most `size`, clamped for the same reason the
    /// prefetch's copy is: a zero would loop forever rather than crash.
    func batched(by size: Int) -> [[Element]] {
        let size = Swift.max(1, size)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
