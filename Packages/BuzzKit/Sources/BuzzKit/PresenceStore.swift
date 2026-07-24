import NostrCore

/// The in-memory home of ephemeral presence (kind 20001) and typing (kind 20002)
/// state, keyed by `(channel, pubkey)`.
///
/// Presence and typing are ephemeral by definition: relays never store them
/// (``NostrCore/EventKind/isEphemeral``), and neither do we. ``BuzzEventStore``
/// verifies these kinds at the ingest choke point and then *diverts* them here —
/// into ``IngestResult/ephemeral`` — instead of writing them to the log. Storing
/// seconds-lived heartbeats would grow an append-only log without bound for data
/// that is meaningless almost as soon as it lands. This actor is that diversion's
/// destination and the whole of its persistence: purely in memory, never touching
/// GRDB.
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
/// is lazy on read (a record past its deadline is already invisible to a
/// ``snapshot(for:)``) and pushed to observers by ``sweep()``, the seam the sync
/// engine's timer will drive in a later step. This actor owns no timer of its own.
///
/// # The TTLs are placeholders
///
/// 60 s presence / 10 s typing are the spec's inferred defaults, to be tuned
/// against upstream in Phase 3. Both are injectable so that tuning is a call-site
/// change, not an edit here.
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

    private var presenceRecords: [Key: PresenceRecord] = [:]
    private var typingRecords: [Key: TypingRecord] = [:]

    /// Per-channel observer continuations.
    private var observers: [String: [Int: AsyncStream<ChannelPresence>.Continuation]] = [:]
    /// The last snapshot published per channel, so a real change is told from a
    /// no-op and a repeated identical yield is suppressed. A channel that has
    /// decayed to empty carries no entry, so the map does not accumulate one row
    /// per channel ever seen.
    private var lastPublished: [String: ChannelPresence] = [:]
    private var nextObserverID = 0

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - presenceTTL: how long a presence heartbeat stays live. Default 60 s.
    ///   - typingTTL: how long a typing indicator stays live. Default 10 s.
    ///   - now: the monotonic clock. Defaults to the system continuous clock;
    ///     tests inject a hand-advanced one.
    public init(
        presenceTTL: Duration = .seconds(60),
        typingTTL: Duration = .seconds(10),
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
    /// verified at the choke point, so this trusts each event's identity. Kinds
    /// other than presence and typing are ignored: a future ephemeral kind rides
    /// the same divert path but is not this store's to interpret. An ephemeral with
    /// no `h` tag has no channel to be placed in and is skipped.
    ///
    /// Each touched channel publishes at most once, after the whole batch is
    /// folded, so a flush of ten heartbeats for one channel wakes its observers
    /// once, not ten times.
    ///
    /// This is the seam the sync engine drives: it forwards `store.ingest(…).ephemeral`
    /// straight here. Nothing else is wired in this step.
    public func apply(_ events: [NostrEvent]) {
        var touched: Set<String> = []
        for event in events {
            guard let channel = event.groupID else { continue }
            let changed: Bool
            if event.kind == .presence {
                changed = applyPresence(event, channel: channel)
            } else if event.kind == .typing {
                changed = applyTyping(event, channel: channel)
            } else {
                continue
            }
            if changed { touched.insert(channel) }
        }
        for channel in touched {
            publish(channel)
        }
    }

    /// Records a presence heartbeat, or clears the peer on an `"offline"` status.
    /// Returns whether the backing map changed.
    private func applyPresence(_ event: NostrEvent, channel: String) -> Bool {
        let key = Key(channel: channel, pubkey: event.pubkey)
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

    /// Records a typing indicator. Returns whether the backing map changed.
    private func applyTyping(_ event: NostrEvent, channel: String) -> Bool {
        let key = Key(channel: channel, pubkey: event.pubkey)
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

    /// Physically evicts every lapsed record and republishes any channel whose
    /// snapshot shrank as a result.
    ///
    /// Expiry is otherwise lazy — a lapsed record is already invisible to a
    /// ``snapshot(for:)`` read — so this exists for the *push* half of observation:
    /// a typing indicator must vanish from a subscribed UI when it lapses, not only
    /// when the next event happens to arrive. The sync engine drives this on a timer
    /// in a later step; this actor owns no timer itself.
    public func sweep() {
        let channels = Set(presenceRecords.keys.map(\.channel))
            .union(typingRecords.keys.map(\.channel))
        for channel in channels {
            publish(channel)
        }
    }

    // MARK: - Observation

    /// A live feed of one channel's presence and typing, seeded with the current
    /// snapshot so a new subscriber never misses the state it subscribed into
    /// (mirroring the connection-state stream in the transport layer).
    public func presence(for channel: String) -> AsyncStream<ChannelPresence> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChannelPresence.self)
        let id = nextObserverID
        nextObserverID += 1
        observers[channel, default: [:]][id] = continuation
        continuation.yield(snapshotNow(channel))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id, channel: channel) }
        }
        return stream
    }

    /// The current snapshot for a channel, lapsed records already excluded. A pure
    /// read: it neither mutates state nor notifies observers.
    public func snapshot(for channel: String) -> ChannelPresence {
        snapshotNow(channel)
    }

    private func removeObserver(_ id: Int, channel: String) {
        observers[channel]?.removeValue(forKey: id)
        if observers[channel]?.isEmpty == true {
            observers.removeValue(forKey: channel)
        }
    }

    // MARK: - Publishing

    /// Evicts lapsed records for one channel, then yields a fresh snapshot to its
    /// observers only if it differs from the last one published.
    private func publish(_ channel: String) {
        evict(channel)
        let snapshot = snapshotNow(channel)
        let previous = lastPublished[channel] ?? .empty(channel)
        guard previous != snapshot else { return }
        if snapshot.isEmpty {
            lastPublished.removeValue(forKey: channel)
        } else {
            lastPublished[channel] = snapshot
        }
        guard let channelObservers = observers[channel] else { return }
        for continuation in channelObservers.values {
            continuation.yield(snapshot)
        }
    }

    /// Removes lapsed records for one channel from the backing maps.
    private func evict(_ channel: String) {
        let cutoff = now()
        presenceRecords = presenceRecords.filter { key, record in
            key.channel != channel || record.deadline > cutoff
        }
        typingRecords = typingRecords.filter { key, record in
            key.channel != channel || record.deadline > cutoff
        }
    }

    /// Builds the live snapshot for a channel, treating any record past its deadline
    /// as already gone — expiry is visible on read whether or not a sweep has
    /// physically evicted it. Ordered by pubkey so equal states compare equal.
    private func snapshotNow(_ channel: String) -> ChannelPresence {
        let cutoff = now()
        let present = presenceRecords
            .filter { $0.key.channel == channel && $0.value.deadline > cutoff }
            .map { PresenceMember(pubkey: $0.value.pubkey, status: $0.value.status) }
            .sorted { $0.pubkey < $1.pubkey }
        let typing = typingRecords
            .filter { $0.key.channel == channel && $0.value.deadline > cutoff }
            .map(\.value.pubkey)
            .sorted()
        return ChannelPresence(channel: channel, present: present, typing: typing)
    }

    // MARK: - Backing types

    /// The one presence content that clears state rather than setting it.
    private static let offlineStatus = "offline"

    /// The composite identity of a presence or typing record.
    private struct Key: Hashable {
        let channel: String
        let pubkey: String
    }

    private struct PresenceRecord {
        let pubkey: String
        let status: PresenceStatus
        let createdAt: Int64
        let deadline: ContinuousClock.Instant
    }

    private struct TypingRecord {
        let pubkey: String
        let createdAt: Int64
        let deadline: ContinuousClock.Instant
    }
}
