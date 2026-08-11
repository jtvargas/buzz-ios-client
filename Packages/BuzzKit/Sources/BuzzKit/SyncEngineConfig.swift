import Foundation

/// Timing and topology knobs for a ``SyncEngine``.
///
/// Each value is a policy the engine reads rather than hardcodes, so a test can
/// pin the numbers and production can tune them without touching the state
/// machine. Defaults follow the Phase-2 spec's sync topology.
public struct SyncEngineConfig: Sendable {
    /// How far back the live content filter's `since` reaches from "now" — the
    /// small overlap that keeps the connect gap from dropping an event the socket
    /// was mid-delivering. NIP-CW deep history is the window reconcile's job, not
    /// this filter's.
    public var liveSinceWindow: TimeInterval

    /// How often the engine drives ``PresenceStore/sweep()`` so a lapsed typing or
    /// presence record vanishes from a subscribed UI on time, rather than only when
    /// the next event happens to arrive. The store owns no timer of its own. Defaults
    /// to 1 s — the upstream typing-prune cadence — so an 8 s typing indicator clears
    /// within roughly a second of lapsing.
    public var presenceSweepInterval: Duration

    /// The per-page row budget for a window reconcile. The relay clamps it to its
    /// documented range; 50 is the NIP-CW recommendation.
    public var windowPageLimit: Int

    /// The row budget for one ``SyncEngine/openThread(root:)``, and with it the line
    /// between a thread this device now holds in full and one it holds only the top of.
    ///
    /// Defaults to the relay's own ceiling on an unbounded socket filter (`query_events`
    /// clamps to 1000), so the default changes nothing on the wire — a bare filter was
    /// already getting exactly this. Stating it makes a clipped answer recognisable:
    /// a full page back means there may be more, and only a fetch that was *not* clipped
    /// may claim the thread, because that claim is what suppresses the relay's tally in
    /// favour of this device's own count.
    public var threadFetchLimit: Int

    /// How many threads one ``SyncEngine/prefetchThreads(in:)`` may reach for.
    ///
    /// The prefetch exists so a Threads screen has content before anything has been
    /// opened, and this is the number that keeps it from growing with a channel's
    /// history: the *most recently active* threads, not every thread that has ever had
    /// a reply. Twenty because the screen's own cap is fifty and a reader catching up
    /// reads the top of it — reaching for all fifty would triple the cost of arriving
    /// for rows most people never scroll to.
    public var threadPrefetchRootLimit: Int

    /// The reply budget for one prefetched thread.
    ///
    /// Deliberately far below ``threadFetchLimit``: this is a fetch nobody asked for,
    /// issued for twenty threads at once, and its job is to make a row *readable* —
    /// the newest reply, who is in it, and how much is unread. Twenty covers all of
    /// that for any thread of ordinary size, and a thread larger than that is one the
    /// reader will open, at which point ``SyncEngine/openThread(root:)`` fetches it
    /// properly.
    ///
    /// The consequence is that a prefetched thread may be held only in part, and the
    /// reads over it say so rather than presenting a floor as a total — see
    /// ``ThreadActivity/newReplyCountIsExact``.
    public var threadPrefetchReplyLimit: Int

    /// How many times the launch pass may repeat the prefetch before it stops, whatever
    /// is left behind — see ``SyncEngine/settleThreadPrefetch(generation:)``.
    ///
    /// One pass reaches for ``threadPrefetchRootLimit`` threads, and a pass records what
    /// it asked about, so repeating it pages down the backlog rather than re-asking. This
    /// is the number that stops that paging from walking a whole history on a device that
    /// has been away for a month.
    ///
    /// Three, which is sixty threads and at most six requests: a cold launch that has to
    /// reach further than the sixty most recently active threads in the reader's whole
    /// community is catching up on more than anyone reads in one sitting, and the rest is
    /// still reachable — the next launch pages again from where this one stopped, and
    /// arriving on a screen asks for that screen's own threads directly.
    public var threadPrefetchLaunchPasses: Int

    /// How far back ``SyncEngine/settleThreadSweep(generation:)`` will ask about a thread
    /// it has no evidence about.
    ///
    /// The sweep's candidates are chosen without consulting the relay's tally, so nothing
    /// bounds them but this. Fourteen days, which is well past the watermark boundary the
    /// defect lives at — a channel read daily exposes anything older than roughly a day —
    /// while keeping the candidate set to something a few passes can rotate through.
    ///
    /// A thread that has been idle longer than this and then gains a reply is the residual
    /// gap, and it is deliberate: closing it means asking about every root this device has
    /// ever held, on a schedule, forever. The live subscription covers it while the app is
    /// running, and opening the thread covers it at any time.
    public var threadSweepHorizon: TimeInterval

    /// How many threads one sweep pass may ask about.
    ///
    /// Forty, which is four requests at ``SyncEngine/maxFiltersPerRequest``. It is a
    /// throughput cap and not a coverage ceiling: candidates come back least-recently-swept
    /// first, so successive passes rotate through the backlog rather than re-serving the
    /// same capful.
    public var threadSweepRootLimit: Int

    /// How many of a channel's relay notices one reconcile reaches for.
    ///
    /// These have to be asked for separately from everything else, and the reason is
    /// worth knowing: the relay stores a kind-40099 notice with `insert_event` rather
    /// than `insert_event_with_thread_metadata`, so it never gets a `thread_metadata`
    /// row — and a channel window page is computed *from* that table. No `kinds` on a
    /// window request can produce one. See ``SyncEngine/assembleNotices(_:generation:)``.
    ///
    /// Two hundred, well above ``windowPageLimit``: a notice is far rarer than a
    /// message but it is also far older on average, since it is the only kind of row
    /// that can predate every message still in a channel.
    public var noticeBackfillLimit: Int

    /// The longest one staged-media upload may hold an authored event before it
    /// becomes an explicit, retryable send failure.
    public var mediaUploadDeadline: Duration

    /// The shortest gap between two send-driven reconnect requests.
    ///
    /// A queued send asks the connection to stop waiting out its backoff rather than
    /// sitting until the next `.ready` arrives on its own schedule — see
    /// ``SyncEngine/nudgeConnection()``. That request must be rate-limited: a nudge
    /// arriving while the connection is still backing off resets its attempt counter,
    /// so an ungated one would let a run of sends retry a dead network on a five-second
    /// loop for as long as the reader kept typing.
    ///
    /// Five seconds, because only the *first* nudge after a disconnect does anything
    /// useful — by the second one a reconnect is already in flight and the connection
    /// ignores it — so a longer window costs nothing and bounds the failure case
    /// tighter. Still six times shorter than ``ReconnectPolicy/cap``, which is the wait
    /// it exists to cut short.
    public var connectionNudgeInterval: TimeInterval

    public init(
        liveSinceWindow: TimeInterval = 5,
        presenceSweepInterval: Duration = .seconds(1),
        windowPageLimit: Int = 50,
        threadFetchLimit: Int = 1000,
        threadPrefetchRootLimit: Int = 20,
        threadPrefetchReplyLimit: Int = 20,
        threadPrefetchLaunchPasses: Int = 3,
        threadSweepHorizon: TimeInterval = 14 * 24 * 60 * 60,
        threadSweepRootLimit: Int = 40,
        noticeBackfillLimit: Int = 200,
        mediaUploadDeadline: Duration = .seconds(270),
        connectionNudgeInterval: TimeInterval = 5
    ) {
        self.liveSinceWindow = liveSinceWindow
        self.presenceSweepInterval = presenceSweepInterval
        self.windowPageLimit = windowPageLimit
        self.threadFetchLimit = threadFetchLimit
        self.threadPrefetchRootLimit = threadPrefetchRootLimit
        self.threadPrefetchReplyLimit = threadPrefetchReplyLimit
        self.threadPrefetchLaunchPasses = threadPrefetchLaunchPasses
        self.threadSweepHorizon = threadSweepHorizon
        self.threadSweepRootLimit = threadSweepRootLimit
        self.noticeBackfillLimit = noticeBackfillLimit
        self.mediaUploadDeadline = mediaUploadDeadline
        self.connectionNudgeInterval = connectionNudgeInterval
    }

    public static let `default` = SyncEngineConfig()
}
