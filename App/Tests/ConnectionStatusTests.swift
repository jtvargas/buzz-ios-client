import BuzzKit
@testable import Hive
import Testing

/// What a conversation says about the connection, and what it stays quiet about.
///
/// The word is the only part of ``ConnectionStatusIndicatorView`` a test can reach —
/// nothing in this suite renders — but it is the part that carries the decision: which
/// states are worth interrupting a reader for, and how a drop is told from a cold
/// start when the engine reports both as `.starting`.
@Suite("Connection status")
struct ConnectionStatusTests {
    private func message(_ state: SyncEngine.State, connectedBefore: Bool) -> String? {
        ConnectionStatusIndicatorView.message(for: state, hasConnectedBefore: connectedBefore)
    }

    @Test("A live connection says nothing")
    func runningIsSilent() {
        #expect(message(.running, connectedBefore: true) == nil)
        #expect(message(.running, connectedBefore: false) == nil)
    }

    @Test("A backgrounded connection says nothing")
    func suspendedIsSilent() {
        // The socket was released on purpose and nobody is reading this screen; by the
        // time somebody is, the resume has already moved the state on.
        #expect(message(.suspended, connectedBefore: true) == nil)
    }

    @Test("Starting reads as connecting on a cold start and reconnecting after a drop")
    func startingDependsOnHavingBeenLive() {
        // The engine cannot tell these apart — both are `.starting`. A reader can: one
        // is the app opening, the other is the app they were already using going quiet.
        #expect(message(.starting, connectedBefore: false) == "Connecting…")
        #expect(message(.starting, connectedBefore: true) == "Reconnecting…")
    }

    @Test("A stopped engine reads as offline")
    func stoppedReadsAsOffline() {
        #expect(message(.stopped, connectedBefore: true) == "Offline")
        #expect(message(.stopped, connectedBefore: false) == "Offline")
    }

    @Test("The strip waits before speaking")
    func theDelayIsLongEnoughToCoverAnOrdinaryReconnect() {
        // A reconnect that lands quickly must pass in silence: a capsule that appears
        // and vanishes over a conversation draws the eye to something already resolved.
        // One second covers a foreground probe finding a dead socket and the first
        // backoff step, whose ceiling is `ReconnectPolicy.base`.
        #expect(ConnectionStatusIndicatorView.settleDelay >= .seconds(1))
    }
}
