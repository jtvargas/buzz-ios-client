import NostrCore

/// The in-memory home of ephemeral presence (kind 20001) and typing (kind 20002)
/// state.
///
/// # Two keyings, one store (S-5)
///
/// Presence and typing key differently because the relay scopes them differently.
/// **Presence is workspace-global**: the upstream builder emits a bare status with
/// no `h` tag and the relay fans it out to every subscriber, so a peer is "online"
/// wherever they last published — this store keys presence by **pubkey alone** and
/// accepts an `h`-less event (an `h`, if present, is ignored). **Typing is
/// channel-scoped**: the relay checks channel membership for a channel-tagged
/// ephemeral and rejects a non-member, so typing carries `["h", channel]` and this
/// store keys it by **(channel, pubkey)**. A typing event with no channel has
/// nowhere to be placed and is dropped.
///
/// Presence and typing are ephemeral by definition: relays never store them
/// (``NostrCore/EventKind/isEphemeral``), and neither do we. ``BuzzEventStore``
/// verifies these kinds at the ingest choke point and then *diverts* them here —
/// into ``IngestResult/ephemeral`` — instead of writing them to the log. This actor
/// is that diversion's destination and the whole of its persistence: purely in
/// memory, never touching GRDB.
///
/// # Why an actor
///
/// An ingest flush, a TTL sweep, and a UI subscription all mutate the same maps.
/// Actor isolation serializes them, so an observer never sees a torn snapshot — a
/// member half-added, a typer dropped mid-read.
///
/// # Time is injected
///
/// Every deadline is measured from an injected monotonic clock, never a wall-clock
/// read. Two reasons. An event's `created_at` is author-controlled and skewable, so
/// liveness is timed from *local receipt*, not a timestamp a peer chose. And a test
/// drives expiry by advancing the injected clock — no sleeps, no real time. Expiry
/// is lazy on read (a record past its deadline is already invisible to a snapshot)
/// and pushed to observers by ``sweep()``, the seam the sync engine's timer drives.
/// This actor owns no timer of its own.
///
/// # TTLs
///
/// Presence 150 s, typing 8 s (spec §Step 2, source-derived: typing matches the
/// desktop 8 s TTL; presence is 2.5× the 60 s heartbeat, so one dropped heartbeat
/// does not flap the dot). Both are injectable so tuning is a call-site change.
public actor PresenceStore {
    // MARK: - Injected collaborators

    /// How long a presence heartbeat buys before it is treated as stale. Measured
    /// from local receipt, not the event's `created_at`.
    let presenceTTL: Duration
    /// How long a typing indicator lasts. Much shorter: typing has no explicit stop
    /// signal — a client simply stops sending, and the indicator lapses.
    let typingTTL: Duration
    /// The monotonic clock, injected so a test pins expiry deterministically.
    let now: @Sendable () -> ContinuousClock.Instant

    // MARK: - State

    /// Workspace-global presence, keyed by pubkey (S-5): a peer is present in the
    /// workspace, not in a channel.
    var presenceRecords: [String: PresenceRecord] = [:]
    /// Per-channel typing, keyed by `(channel, pubkey)` (S-5).
    var typingRecords: [TypingKey: TypingRecord] = [:]

    /// Observers of the global presence roster.
    var presenceObservers: [Int: AsyncStream<[PresenceMember]>.Continuation] = [:]
    /// Per-channel observers of who is typing.
    var typingObservers: [String: [Int: AsyncStream<[String]>.Continuation]] = [:]

    /// The last roster published, so a real change is told from a no-op and an
    /// identical repeat yield is suppressed.
    var lastPublishedPresence: [PresenceMember] = []
    /// The last typer list published per channel. A channel that decayed to empty
    /// carries no entry, so the map does not accumulate a row per channel ever seen.
    var lastPublishedTyping: [String: [String]] = [:]
    var nextObserverID = 0

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - presenceTTL: how long a presence heartbeat stays live. Default 150 s.
    ///   - typingTTL: how long a typing indicator stays live. Default 8 s.
    ///   - now: the monotonic clock. Defaults to the system continuous clock;
    ///     tests inject a hand-advanced one.
    public init(
        presenceTTL: Duration = .seconds(150),
        typingTTL: Duration = .seconds(8),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.presenceTTL = presenceTTL
        self.typingTTL = typingTTL
        self.now = now
    }

    // MARK: - Ingest seam

    /// Folds a batch of diverted ephemerals into presence and typing state.
    ///
    /// The batch is exactly what ``IngestResult/ephemeral`` carried, already
    /// verified at the choke point, so this trusts each event's identity. Presence
    /// (20001) is folded into the global roster keyed by pubkey — an `h`-less event
    /// is accepted. Typing (20002) is folded per channel from its `h` tag — an
    /// `h`-less typing event is skipped. Other ephemeral kinds ride the same divert
    /// path but are not this store's to interpret and are ignored.
    ///
    /// Presence publishes at most once and each touched typing channel at most once,
    /// after the whole batch is folded — a flush of ten heartbeats wakes the roster's
    /// observers once, not ten times.
    ///
    /// This is the seam the sync engine drives: it forwards
    /// `store.ingest(…).ephemeral` straight here.
    public func apply(_ events: [NostrEvent]) {
        var presenceChanged = false
        var touchedTypingChannels: Set<String> = []
        for event in events {
            if event.kind == .presence {
                if applyPresence(event) { presenceChanged = true }
            } else if event.kind == .typing {
                guard let channel = event.groupID else { continue }
                if applyTyping(event, channel: channel) { touchedTypingChannels.insert(channel) }
            }
        }
        if presenceChanged { publishPresence() }
        for channel in touchedTypingChannels { publishTyping(channel) }
    }

    /// Records a presence heartbeat under the peer's pubkey (workspace-global), or
    /// clears the peer on an `"offline"` status. Returns whether the roster changed.
    private func applyPresence(_ event: NostrEvent) -> Bool {
        let key = event.pubkey
        // A relay can redeliver an older heartbeat after a reconnect; an older one
        // must never override a newer status or extend a liveness the newer one
        // already superseded. The staleness guard the projections use, in miniature.
        if let existing = presenceRecords[key], event.createdAt < existing.createdAt {
            return false
        }
        let raw = statusString(event)
        if raw == Self.offlineStatus {
            // "offline" is a departure, not a status — the peer leaves the roster.
            return presenceRecords.removeValue(forKey: key) != nil
        }
        presenceRecords[key] = PresenceRecord(
            pubkey: event.pubkey,
            status: PresenceStatus(raw),
            createdAt: event.createdAt,
            deadline: now().advanced(by: presenceTTL)
        )
        return true
    }

    /// Records a typing indicator under `(channel, pubkey)`. Returns whether the
    /// channel's typer set changed.
    private func applyTyping(_ event: NostrEvent, channel: String) -> Bool {
        let key = TypingKey(channel: channel, pubkey: event.pubkey)
        if let existing = typingRecords[key], event.createdAt < existing.createdAt {
            return false
        }
        typingRecords[key] = TypingRecord(
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            deadline: now().advanced(by: typingTTL)
        )
        return true
    }

    /// The status a presence event announces, preferring its content and falling
    /// back to the `["status", …]` tag the SDK also writes. Empty when neither is
    /// present — a degenerate heartbeat, kept as ``PresenceStatus/other(_:)`` rather
    /// than guessed at.
    private func statusString(_ event: NostrEvent) -> String {
        if !event.content.isEmpty { return event.content }
        return event.firstValue(forTag: "status") ?? ""
    }

    // MARK: - Expiry

    /// Physically evicts every lapsed record and republishes the roster and any
    /// typing channel whose snapshot shrank as a result.
    ///
    /// Expiry is otherwise lazy — a lapsed record is already invisible to a snapshot
    /// read — so this exists for the *push* half of observation: a typing indicator
    /// must vanish from a subscribed UI when it lapses, not only when the next event
    /// happens to arrive. The sync engine drives this on a timer; this actor owns no
    /// timer itself.
    public func sweep() {
        publishPresence()
        for channel in Set(typingRecords.keys.map(\.channel)) {
            publishTyping(channel)
        }
    }

    // MARK: - Backing types

    /// The one presence content that clears state rather than setting it.
    static let offlineStatus = "offline"

    /// The composite identity of a typing record.
    struct TypingKey: Hashable {
        let channel: String
        let pubkey: String
    }

    struct PresenceRecord {
        let pubkey: String
        let status: PresenceStatus
        let createdAt: Int64
        let deadline: ContinuousClock.Instant
    }

    struct TypingRecord {
        let pubkey: String
        let createdAt: Int64
        let deadline: ContinuousClock.Instant
    }
}
