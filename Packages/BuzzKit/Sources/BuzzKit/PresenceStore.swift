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
/// store keys it by **(channel, thread, pubkey)**. A typing event with no channel has
/// nowhere to be placed and is dropped.
///
/// # Why typing carries a thread as well as a channel
///
/// A typing indicator built by the agent harness carries the NIP-10 `e` tags of the
/// message it is about to reply to, exactly as the reply itself will. Keyed by channel
/// alone, the thread somebody is actually writing in shows nobody — every indicator in
/// the channel arrives at the channel's own level and nowhere else. So a record is keyed
/// by the reply's own scope: the thread root when the event names one, the channel
/// itself when it does not. It is the same fact the desktop client keys on
/// (`useChannelTyping`'s `threadHeadId`), taken from the root marker rather than the
/// parent so a reply *inside* a thread still scopes to that thread.
///
/// Reading is asymmetric, and deliberately so — see ``TypingAudience``. A thread asks
/// for its own scope and gets only the people writing in it. A channel asks for the
/// whole channel and gets everyone writing anywhere in it, threads included: an agent
/// replying in a thread under a message is the workspace's most common shape by far, and
/// a channel that fell silent for it would be answering "is anyone working on this" with
/// "no". Precise where a reader can act on the precision; complete where they cannot.
///
/// # Why a message clears typing
///
/// Typing has no stop signal — a client stops publishing and the indicator lapses. That
/// leaves the eight seconds after somebody sends: the reply is on screen and the strip
/// under it still says they are typing it. So an arriving message is read as the end of
/// its author's typing in the scope it landed in, both retroactively (the record is
/// dropped) and forwards (a typing event published no later than the message is refused
/// — the two race on the wire and arrive in either order).
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
    /// Per-scope typing, keyed by `(channel, thread, pubkey)` (S-5).
    var typingRecords: [TypingKey: TypingRecord] = [:]
    /// The newest message seen from each author in each scope, held only as long as a
    /// typing indicator could still be in flight behind it. This is what refuses the
    /// typing event a client published a moment *before* the message it announced —
    /// see the type's note.
    var messageMarks: [TypingKey: MessageMark] = [:]

    /// Observers of the global presence roster.
    var presenceObservers: [Int: AsyncStream<[PresenceMember]>.Continuation] = [:]
    /// Per-audience observers of who is typing.
    var typingObservers: [TypingAudience: [Int: AsyncStream<[String]>.Continuation]] = [:]

    /// The last roster published, so a real change is told from a no-op and an
    /// identical repeat yield is suppressed.
    var lastPublishedPresence: [PresenceMember] = []
    /// The last typer list published per audience. One that decayed to empty carries no
    /// entry, so the map does not accumulate a row per audience ever seen.
    var lastPublishedTyping: [TypingAudience: [String]] = [:]
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
        var touched: Set<TypingScope> = []
        for event in events {
            if event.kind == .presence {
                if applyPresence(event) { presenceChanged = true }
            } else if event.kind == .typing {
                guard let scope = Self.scope(of: event) else { continue }
                if applyTyping(event, scope: scope) { touched.insert(scope) }
            }
        }
        if presenceChanged { publishPresence() }
        publishTyping(touched)
    }

    /// Reads a batch of newly-stored messages as the end of their authors' typing.
    ///
    /// The engine hands this the events it just *inserted*, so a reconnect replaying a
    /// message already in the log does not re-clear a typing indicator that has since
    /// legitimately started again. Each message clears its author's record in the scope
    /// it landed in — a thread reply ends typing in that thread, a channel message ends
    /// it in the channel — and leaves a mark that refuses any typing event published no
    /// later than it. See the type note on ``MessageMark``.
    public func messagesArrived(_ events: [NostrEvent]) {
        var touched: Set<TypingScope> = []
        for event in events {
            guard let scope = Self.scope(of: event) else { continue }
            let key = TypingKey(scope: scope, pubkey: event.pubkey)
            // Newest-wins, the same guard the records themselves carry: a backfill can
            // hand this an older message than one already seen, and the mark must not
            // walk backwards and start admitting typing it had already refused.
            if (messageMarks[key]?.createdAt ?? .min) < event.createdAt {
                messageMarks[key] = MessageMark(
                    createdAt: event.createdAt,
                    deadline: now().advanced(by: typingTTL)
                )
            }
            guard let record = typingRecords[key], record.createdAt <= event.createdAt else { continue }
            typingRecords.removeValue(forKey: key)
            touched.insert(scope)
        }
        publishTyping(touched)
    }

    /// The channel-and-thread a typing indicator or a message belongs to: its `h` tag,
    /// and the NIP-10 root of the thread it is inside (`nil` at the channel's own level).
    ///
    /// The *root* rather than the parent, so a reply to a reply still scopes to the
    /// thread a reader has open. ``NostrCore/ThreadReference`` already falls back to the
    /// parent when only a reply marker is present, which is the shape a two-message
    /// thread has.
    static func scope(of event: NostrEvent) -> TypingScope? {
        guard let channel = event.groupID else { return nil }
        return TypingScope(channel: channel, thread: event.threadReference.rootID)
    }

    /// Records a presence heartbeat under the subject's pubkey (workspace-global), or
    /// clears the subject on an `"offline"` status. Returns whether the roster changed.
    ///
    /// The subject is normally the event's own author — a live heartbeat is bare status
    /// with no `p` tag, and its `pubkey` is who it is about. A relay-synthesized
    /// cold-start snapshot (`bridge.rs` `synthesize_presence`) is different: it is
    /// signed by the *relay* key and carries the subject member in a `["p", pubkey]`
    /// tag, so `event.pubkey` is the relay, not the member. Keying by the `p` tag when
    /// present and the author otherwise folds both into the one roster under the right
    /// identity.
    private func applyPresence(_ event: NostrEvent) -> Bool {
        let key = event.firstValue(forTag: "p") ?? event.pubkey
        // A relay can redeliver an older heartbeat after a reconnect; an older one
        // must never override a newer status or extend a liveness the newer one
        // already superseded. The staleness guard the projections use, in miniature.
        if let existing = presenceRecords[key], event.createdAt < existing.createdAt {
            return false
        }
        let raw = statusString(event)
        if raw == Self.offlineStatus {
            // "offline" is a departure, not a status — the subject leaves the roster.
            return presenceRecords.removeValue(forKey: key) != nil
        }
        presenceRecords[key] = PresenceRecord(
            pubkey: key,
            status: PresenceStatus(raw),
            createdAt: event.createdAt,
            deadline: now().advanced(by: presenceTTL)
        )
        return true
    }

    /// Records a typing indicator under `(channel, thread, pubkey)`. Returns whether the
    /// scope's typer set changed.
    private func applyTyping(_ event: NostrEvent, scope: TypingScope) -> Bool {
        let key = TypingKey(scope: scope, pubkey: event.pubkey)
        // Already superseded by a message from the same author in the same scope. A
        // client publishes its typing on a timer and its message the moment the text is
        // ready, so the last indicator of a turn is routinely still in flight when the
        // message it announced arrives — without this it re-raises the strip for the
        // remainder of the TTL, under the reply it was announcing.
        if let mark = messageMarks[key], event.createdAt <= mark.createdAt { return false }
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
    /// typing scope whose snapshot shrank as a result.
    ///
    /// Expiry is otherwise lazy — a lapsed record is already invisible to a snapshot
    /// read — so this exists for the *push* half of observation: a typing indicator
    /// must vanish from a subscribed UI when it lapses, not only when the next event
    /// happens to arrive. The sync engine drives this on a timer; this actor owns no
    /// timer itself.
    public func sweep() {
        publishPresence()
        publishTyping(Set(typingRecords.keys.map(\.scope)))
        // The marks outlive nothing: once no typing event old enough to be refused can
        // still be in flight, the mark is only a row in a map that would otherwise grow
        // by one per author per scope for the life of the process.
        let cutoff = now()
        messageMarks = messageMarks.filter { $0.value.deadline > cutoff }
    }

    // MARK: - Backing types

    /// The one presence content that clears state rather than setting it.
    static let offlineStatus = "offline"

    /// Where a typing indicator applies: one channel, and optionally one thread inside
    /// it. `thread` is `nil` for the channel's own level, which is also what a client
    /// that knows nothing about threads publishes.
    struct TypingScope: Hashable {
        let channel: String
        var thread: String?
    }

    /// Who is asking. A scope is where an indicator *is*; an audience is what a surface
    /// wants to hear about, and the two are not the same question.
    ///
    /// A thread asks for its own scope exactly. A channel asks for all of itself —
    /// including its threads — because a reader on the channel screen cannot see which
    /// thread the work is in and is better served by "somebody is writing" than by
    /// silence. See the note on ``PresenceStore``.
    enum TypingAudience: Hashable {
        case channel(String)
        case thread(TypingScope)

        /// Whether an indicator recorded in `scope` should reach this audience.
        func admits(_ scope: TypingScope) -> Bool {
            switch self {
            case let .channel(channel): scope.channel == channel
            case let .thread(mine): scope == mine
            }
        }

        /// The audiences a change in `scope` must be published to: the thread it is in,
        /// and the channel that contains it.
        static func containing(_ scope: TypingScope) -> [TypingAudience] {
            [.thread(scope), .channel(scope.channel)]
        }
    }

    /// The composite identity of a typing record.
    struct TypingKey: Hashable {
        let scope: TypingScope
        let pubkey: String
    }

    /// The newest message an author has landed in one scope, and how long that fact is
    /// worth keeping.
    ///
    /// Held for the typing TTL, because that is the whole window in which a typing event
    /// this mark would refuse could still show up: anything older than the TTL is already
    /// lapsed on arrival and never becomes a visible indicator.
    struct MessageMark {
        let createdAt: Int64
        let deadline: ContinuousClock.Instant
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
