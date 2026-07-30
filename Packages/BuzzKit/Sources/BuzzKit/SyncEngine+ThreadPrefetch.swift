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
        let candidates = (try? store.threadPrefetchCandidates(
            channel: channel,
            limit: config.threadPrefetchRootLimit
        )) ?? []
        guard !candidates.isEmpty else { return }

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
                return
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
