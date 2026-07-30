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

    public init(
        liveSinceWindow: TimeInterval = 5,
        presenceSweepInterval: Duration = .seconds(1),
        windowPageLimit: Int = 50,
        threadFetchLimit: Int = 1000
    ) {
        self.liveSinceWindow = liveSinceWindow
        self.presenceSweepInterval = presenceSweepInterval
        self.windowPageLimit = windowPageLimit
        self.threadFetchLimit = threadFetchLimit
    }

    public static let `default` = SyncEngineConfig()
}
