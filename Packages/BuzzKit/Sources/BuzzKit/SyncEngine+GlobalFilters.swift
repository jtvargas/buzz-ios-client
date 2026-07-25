import Foundation
import NostrCore

/// The two filters that make up the one global live REQ: the narrowed content filter
/// and the membership filter. Both are `#h`-less, so the whole REQ is global — which
/// is exactly what these kinds require. Channel-scoped traffic rides the standing
/// per-channel subscriptions (``SyncEngine/contentFilter(forChannel:)``).
extension SyncEngine {
    /// The global content filter: only the kinds a `#h`-less (global) subscription can
    /// actually receive — profile metadata (0) and workspace presence (20001).
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
            kinds: [.metadata, .presence],
            since: Int64(now().timeIntervalSince1970) - Int64(config.liveSinceWindow)
        )
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
