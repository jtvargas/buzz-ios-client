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

    public init(
        liveSinceWindow: TimeInterval = 5,
        presenceSweepInterval: Duration = .seconds(1),
        windowPageLimit: Int = 50
    ) {
        self.liveSinceWindow = liveSinceWindow
        self.presenceSweepInterval = presenceSweepInterval
        self.windowPageLimit = windowPageLimit
    }

    public static let `default` = SyncEngineConfig()
}
