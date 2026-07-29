import Foundation

/// Timing and policy knobs for a ``RelayConnection``.
///
/// Every duration here is a policy decision the connection reads rather than
/// hardcodes, so a test can compress them and production can tune them per
/// network without touching the state machine. Defaults suit a relay reached over
/// a mobile network: patient enough not to churn a slow-but-alive link, tight
/// enough to notice a genuinely dead one within tens of seconds.
public struct RelayConnectionConfig: Sendable {
    /// The backoff schedule for reconnect attempts.
    public var reconnectPolicy: ReconnectPolicy
    /// How long the app may stay backgrounded before the socket is released. A
    /// quick app switch that returns inside this window keeps the connection, so
    /// foregrounding does not pay for a full reconnect.
    public var backgroundGrace: Duration
    /// Idle beyond this triggers a liveness ping. "Idle" is time since the last
    /// inbound frame or answered ping, measured by the transport.
    public var pingInterval: Duration
    /// How long a liveness ping has to be answered before the connection is
    /// judged dead. Bounds a half-open socket whose `receive()` would otherwise
    /// hang until the OS gives up.
    public var pingDeadline: Duration
    /// How long a *foreground* liveness probe waits for its pong before judging a
    /// resumed socket dead. Deliberately far tighter than ``pingDeadline``: the
    /// user is waiting on the catch-up, so a socket the background freeze silently
    /// killed must be caught in about a second, not the tens of seconds the idle
    /// watchdog tolerates.
    public var foregroundProbeDeadline: Duration
    /// Idle beyond this declares the connection dead outright, without waiting on
    /// a ping — a stronger bound than ``pingInterval`` + ``pingDeadline`` for a
    /// socket that has gone completely silent.
    public var idleTimeout: Duration
    /// How long an opened socket has to reach ``ConnectionState/ready`` before it
    /// is declared dead and retried.
    ///
    /// The idle watchdog cannot cover this: a successful ping is activity, so it
    /// resets the idle clock, and a socket that is alive at the WebSocket level but
    /// wedged above it — a relay that never issues its challenge, a proxy that
    /// completes the upgrade without forwarding, a lost auth `OK` — pings healthily
    /// forever while never authenticating. Without this bound such a socket rests in
    /// ``ConnectionState/connecting`` for the life of the process. Generous, because
    /// the relay challenges on connect and signing is local: anything approaching it
    /// is a stall, not a slow network.
    public var handshakeTimeout: Duration
    /// The same bound, applied when the app *resumes* mid-handshake. Deliberately far
    /// tighter, for ``foregroundProbeDeadline``'s reason: a handshake frozen by
    /// backgrounding may have been talking to a socket the OS has since dropped, and
    /// the user is now watching the screen wait for it.
    public var foregroundHandshakeDeadline: Duration
    /// The longest a `publish`/`query` will wait for authentication before
    /// failing. A last-resort bound: an unresumed continuation is not
    /// cancellable, so a race no other guard anticipated is caught here.
    public var authTimeout: Duration
    /// The default deadline for a one-shot `query` from REQ to EOSE.
    public var queryTimeout: Duration
    /// The longest a `publish` waits for its `OK`. Bounds a live socket whose
    /// relay never answers — or answers with a frame that fails decode — so a
    /// caller can never hang while subscription traffic keeps the idle
    /// watchdog satisfied.
    public var publishTimeout: Duration

    public init(
        reconnectPolicy: ReconnectPolicy = .default,
        backgroundGrace: Duration = .seconds(5),
        pingInterval: Duration = .seconds(25),
        pingDeadline: Duration = .seconds(10),
        foregroundProbeDeadline: Duration = .seconds(2),
        idleTimeout: Duration = .seconds(40),
        handshakeTimeout: Duration = .seconds(12),
        foregroundHandshakeDeadline: Duration = .seconds(3),
        authTimeout: Duration = .seconds(30),
        queryTimeout: Duration = .seconds(15),
        publishTimeout: Duration = .seconds(15)
    ) {
        self.reconnectPolicy = reconnectPolicy
        self.backgroundGrace = backgroundGrace
        self.pingInterval = pingInterval
        self.pingDeadline = pingDeadline
        self.foregroundProbeDeadline = foregroundProbeDeadline
        self.idleTimeout = idleTimeout
        self.handshakeTimeout = handshakeTimeout
        self.foregroundHandshakeDeadline = foregroundHandshakeDeadline
        self.authTimeout = authTimeout
        self.queryTimeout = queryTimeout
        self.publishTimeout = publishTimeout
    }

    public static let `default` = RelayConnectionConfig()
}
