import Foundation
import NostrCore

/// The two filters that make up the one global live REQ: the narrowed content filter
/// and the membership filter. Both are `#h`-less, so the whole REQ is global — which
/// is exactly what these kinds require. Channel-scoped traffic rides the standing
/// per-channel subscriptions (``SyncEngine/contentFilter(forChannel:)``).
extension SyncEngine {
    /// The global *live* filter: workspace presence (20001), and nothing else.
    ///
    /// **Profile metadata is deliberately not here — do not put it back.** This filter
    /// carries a `since` window a few seconds wide, which is right for presence, whose
    /// whole nature is to be republished constantly, and wrong for anything written
    /// once. A profile is written when someone edits it and then sits untouched for
    /// weeks, so a metadata filter with this `since` matches nothing and the client
    /// never learns a single name or avatar: measured against the live relay, the same
    /// query returned 16 kind-0 events with no `since` and **zero** with `since = now -
    /// 5s`. Names fell back to a short npub and avatars to initials everywhere, which
    /// is exactly the bug this split fixes. Profiles ride ``profileFilter()``.
    ///
    /// **Scoping invariant — do not re-add channel kinds here.** The relay scopes a REQ
    /// by its filters: a REQ is channel-scoped only if *every* filter carries a `#h` tag
    /// query, and channel-scoped events (kind 9/40002/40003/7/5/9005 and the
    /// `#h`-tagged typing 20002) NEVER fan out to a global subscription. This filter is
    /// `#h`-less by design — it is multiplexed with the equally `#h`-less membership
    /// filter, so the whole REQ is global — which means those channel kinds would be
    /// dead weight that never delivers a single live event. They live on the
    /// per-channel standing subscriptions instead. Presence (20001) is channel-less and
    /// reaches a global filter; typing (20002) carries `#h` and does not, so it too
    /// belongs only on the per-channel subs.
    func contentFilter() -> Filter {
        Filter(
            kinds: [.presence],
            since: Int64(now().timeIntervalSince1970) - Int64(config.liveSinceWindow)
        )
    }

    /// Profile metadata (kind 0), with **no `since`** — the reason this is its own
    /// filter rather than a kind added to ``contentFilter()``.
    ///
    /// A replaceable event carries the `created_at` of the last edit, so "recent" is
    /// meaningless for it: a workspace where nobody has changed their picture this month
    /// has no recent profiles at all, and a windowed filter therefore returns nothing.
    /// The agent directory (``agentDirectoryFilter()``) already had to reason this out
    /// for kind 10100; the same reasoning was simply never applied to kind 0.
    ///
    /// Riding the standing global REQ means the replay lands once per session and then
    /// live edits arrive as they happen: the manager re-arms this subscription from its
    /// EOSE-gated cursor after a reconnect, so a reconnect does not re-pay the backfill.
    ///
    /// The limit is newest-first, so a workspace with more profiles than this gets the
    /// most recently edited ones. If that ever bites, the fix is a targeted
    /// `authors`-scoped query for the identities a roster names and the store has no
    /// profile for — not a bigger number here.
    func profileFilter() -> Filter {
        Filter(kinds: [.metadata], limit: 500)
    }

    /// The persisted Buzz agent directory. Unlike presence/profile live traffic,
    /// this must not carry a recent `since`: an unchanged agent definition may be
    /// older than the live window but is still required for autocomplete.
    func agentDirectoryFilter() -> Filter {
        Filter(kinds: [.agentProfile], limit: 100)
    }

    /// The membership filter: relay-signed add/remove notifications scoped to the
    /// authenticated identity, as the relay requires for these p-gated kinds.
    func membershipFilter(selfPubkeyHex: String) -> Filter {
        Filter(
            kinds: [.memberAdded, .memberRemoved],
            tagQueries: ["p": [selfPubkeyHex]]
        )
    }
}
