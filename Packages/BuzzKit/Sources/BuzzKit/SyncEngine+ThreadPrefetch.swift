import Foundation
import NostrCore

public extension SyncEngine {
    /// The most filters one REQ may carry.
    ///
    /// The relay's own cap, not a policy of ours: its protocol parser rejects a REQ with
    /// more than ten filters outright (`crates/buzz-relay/src/protocol.rs`, advertised as
    /// `max_filters: 10` in its NIP-11 document). Exceeding it does not degrade, it fails
    /// the whole request, so the batching below is a correctness constraint rather than a
    /// tuning choice.
    static var maxFiltersPerRequest: Int { 10 }

    /// Fetches the newest replies for the threads this device is behind on, so a screen
    /// that summarises threads has content before any thread has been opened.
    ///
    /// # What this is for
    ///
    /// A `kind:39005` tally lets a *message* advertise its replies without holding them
    /// (``TimelineRow/replyCount``), and that is all a count needs. A thread *summary*
    /// needs more: ``ThreadActivity`` renders the newest reply's text and the faces of
    /// whoever is in the conversation, and no aggregate can supply either. Only replies
    /// can, so on a cold launch the Threads screen is empty until something fetches them.
    ///
    /// # Why it does not simply fetch the channel's replies
    ///
    /// A channel window is `top_level: true` by definition, so replies never arrive as
    /// page rows — and asking for them wholesale is the cost NIP-CW exists to avoid: it
    /// grows with every reply ever written. Nor can a filter ask for "replies" as such,
    /// since a reply is an ordinary `kind:9` distinguished only by its tags. So the ask is
    /// narrowed by *thread*: the tally already says which threads have replies and how
    /// recently, so the fetch reaches for the twenty most recently active
    /// (``SyncEngineConfig/threadPrefetchRootLimit``) and stops.
    ///
    /// # Why one filter per thread rather than one filter listing them all
    ///
    /// A single filter carrying twenty `#e` values ORs them under one global limit
    /// (`crates/buzz-db/src/event.rs`), so the busiest thread fills the budget and the
    /// other nineteen come back empty — a starvation that reads exactly like the bug this
    /// fixes. A REQ's filters are independent queries with independent limits
    /// (`crates/buzz-relay/src/handlers/req.rs`, deduped by id afterwards), so one filter
    /// per thread gets each thread its own budget. Batched at
    /// ``maxFiltersPerRequest``, which is what makes twenty threads two round trips.
    ///
    /// # Why it is safe to call on arrival, before the socket is up
    ///
    /// ``NostrCore/RelayConnection/query(_:timeout:)`` waits for authentication rather
    /// than failing, so a prefetch issued while a cold launch is still connecting
    /// suspends and then runs. Nothing here retries, and nothing needs to.
    ///
    /// # Why calling it on every appearance is cheap
    ///
    /// A successful pass records what it fetched, and a fetched thread stops being a
    /// candidate until it gains new activity — so the second appearance of a screen costs
    /// one local query returning nothing. The work is proportional to what has changed
    /// since the last visit, not to the size of the history or the number of visits.
    ///
    /// - Parameter channel: Restrict to one channel's threads, or `nil` for every channel.
    func prefetchThreads(in channel: String? = nil) async {
        _ = await prefetchThreadPass(in: channel)
    }
}

// MARK: - One pass, and the launch loop over it

/// What one call to ``SyncEngine/prefetchThreads(in:)`` did, for a caller that repeats it.
///
/// The distinction worth having a type for is between the two ways a pass stops early.
/// Nothing to fetch and a dropped socket both leave the store exactly as they found it, so
/// a loop that reads only "did anything change" cannot tell them apart — and gets one of
/// them wrong whichever way it guesses: it either spins through its whole ceiling against a
/// relay that is not answering, or it stops with candidates still outstanding on the
/// ordinary path this feature exists to serve.
enum ThreadPrefetchPass: Equatable {
    /// The local candidate query returned nothing: this device is not behind on any thread
    /// the relay's tallies know about, and there is no more work to ask for now.
    case drained

    /// Every candidate this pass selected was asked about and recorded, and the count is
    /// how many. A count short of ``SyncEngineConfig/threadPrefetchRootLimit`` took the
    /// last of them — the query was not clipped, so a further pass would return nothing.
    case attempted(Int)

    /// A request or a write failed part-way. The candidates in and after that batch were
    /// never recorded, so they are still candidates and an immediate repeat would put the
    /// same question to the same broken socket.
    case interrupted
}

extension SyncEngine {
    /// One pass of ``prefetchThreads(in:)``, reporting what it did.
    ///
    /// Split out from the void-returning entry point rather than replacing it: the screens
    /// call this on arrival through `ThreadPrefetching` and have nothing to do with the
    /// answer, while ``settleThreadPrefetch(generation:)`` cannot loop without it.
    func prefetchThreadPass(in channel: String?) async -> ThreadPrefetchPass {
        let candidates = (try? store.threadPrefetchCandidates(
            channel: channel,
            limit: config.threadPrefetchRootLimit
        )) ?? []
        guard !candidates.isEmpty else { return .drained }

        let replyLimit = config.threadPrefetchReplyLimit
        for batch in candidates.batched(by: Self.maxFiltersPerRequest) {
            // `kind:9` alone is the complete ask, for the same reason it is in
            // ``openThread(root:)``: it is the only kind ``BuzzProjector`` turns into a
            // `thread` row, so nothing else the relay could return would change what this
            // device knows about the thread.
            let filters = batch.map {
                Filter(kinds: [.channelMessage], limit: replyLimit, tagQueries: ["e": [$0.rootID]])
            }
            guard let events = try? await subscriptions.query(filters),
                  (try? await store.ingest(batch: events, phase: .backfill)) != nil
            else {
                // A dropped socket or a failed write: stop, having recorded nothing for
                // this batch. The next visit to the screen asks again from the same place.
                return .interrupted
            }

            for candidate in batch {
                // The attempt is recorded whatever came back — including nothing at all,
                // which is the case the record exists for. See
                // ``BuzzEventStore/recordThreadPrefetch(root:summaryEventID:)``.
                try? await store.recordThreadPrefetch(
                    root: candidate.rootID,
                    summaryEventID: candidate.summaryEventID
                )

                // A thread whose whole conversation fit inside the budget is held in full,
                // and may say so — the same claim, on the same evidence, that
                // ``openThread(root:)`` makes when its own page comes back short. It is
                // what lets a withdrawn reply lower this thread's count without the reader
                // having to open it. Counted per thread rather than over the response,
                // because a batch's filters answer independently and are then deduped.
                if events.count(taggingEvent: candidate.rootID) < replyLimit {
                    try? await store.recordThreadFetch(root: candidate.rootID)
                }
            }
        }
        return .attempted(candidates.count)
    }

    /// Fetches the replies this device is behind on across every channel it holds threads
    /// in, bounded, at the tail of the authoritative launch pass.
    ///
    /// # What this fixes
    ///
    /// Until this existed, the only prefetch on the launch path was
    /// ``settleStarterChannels(joined:generation:)``'s, and that one is scoped by name to
    /// `general` and `welcome-everyone`. Every other channel the reader is in got its
    /// replies only when they arrived on the live socket or when the reader opened the
    /// thread — so on a cold launch a reply written while the phone was asleep was there
    /// in the tally and missing from the screen. That is the "replies arrive late" half of
    /// the defect. It is not the "never arrive" half: a root the relay's window no longer
    /// re-summarises never gets a rising `last_reply_at` and so is never a candidate here
    /// at all, which needs a candidate source that does not read the tally.
    ///
    /// # Why the ask is global rather than a loop over channels
    ///
    /// The starter pass asks per channel, for a reason it states: one global pass takes the
    /// twenty most recently active threads *anywhere*, so two busy channels can take the
    /// whole budget. That is true of one pass and stops being true of a bounded loop —
    /// a pass records every candidate it attempted, so the next pass's query excludes them
    /// and returns the twenty behind. Repeating it pages down the backlog in the order the
    /// candidate query already produces, which is `last_reply_at DESC`. Three reasons that
    /// is the right order to spend a launch budget in:
    ///
    /// 1. **It is the reader's order.** Newest-reply-first is what the Threads screen shows
    ///    and what a reader catching up wants. Per channel spends the same on a dead
    ///    channel's three-week-old thread as on the newest thread in the busiest one.
    /// 2. **It packs.** Filters batch at ``maxFiltersPerRequest`` across the whole pass, so
    ///    sixty threads are six requests however they are distributed. Per channel cannot
    ///    pack across channels: sixteen channels holding four candidates each are sixteen
    ///    requests for forty threads, on the flakiest, busiest moment in the app's life.
    /// 3. **It has a ceiling to state.** This budget is passes × roots, one number to size
    ///    against the relay's request allowance. Per channel is roots × however many
    ///    channels the reader joined, which is not a bound, and bounding it means inventing
    ///    an allocation across channels — the thing the recency order already decides.
    ///
    /// The starter pass is left in front of this one rather than folded into it. It costs
    /// two local queries returning nothing once its channels are settled, and it keeps a
    /// guarantee this one only makes probabilistically: the two channels a new reader opens
    /// first are fetched before the budget meets whatever else is recent.
    ///
    /// # Why it stops on `interrupted`
    ///
    /// A pass that lost the socket recorded nothing for the batch it died in, so its
    /// candidates are still candidates and repeating it re-asks the same question — at
    /// launch, of a connection that has just proved it cannot answer. Stopping costs
    /// nothing: the reader's next screen asks for its own threads, and the next
    /// authoritative pass starts this again from the same place.
    func settleThreadPrefetch(generation: Int) async {
        for _ in 0 ..< max(1, config.threadPrefetchLaunchPasses) {
            guard isCurrent(generation) else { return }
            switch await prefetchThreadPass(in: nil) {
            case .drained, .interrupted:
                return
            case let .attempted(count):
                // Short of the query's own limit means it was not clipped, so there is
                // nothing behind these — stop without spending a pass to be told so.
                guard count >= config.threadPrefetchRootLimit else { return }
            }
        }
    }
}

private extension [NostrEvent] {
    /// How many of these events carry an `e` tag naming `id` — the same predicate the
    /// relay matched the filter on, so this is that filter's own answer counted out of a
    /// batched response.
    ///
    /// Unmarked on purpose: a `#e` filter matches an `e` tag whatever its NIP-10 marker
    /// says, so narrowing this to `reply`-marked tags would count fewer events than the
    /// relay's limit was applied to and call a clipped answer complete.
    func count(taggingEvent id: String) -> Int {
        count { event in
            event.tags.contains { $0.count >= 2 && $0[0] == "e" && $0[1] == id }
        }
    }
}

private extension Array {
    /// The array in order, in runs of at most `size`.
    ///
    /// `size` is trusted to be positive — it is only ever
    /// ``SyncEngine/maxFiltersPerRequest`` — but a zero would loop forever rather than
    /// crash, which is the worse failure, so it is clamped.
    func batched(by size: Int) -> [[Element]] {
        let size = Swift.max(1, size)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
