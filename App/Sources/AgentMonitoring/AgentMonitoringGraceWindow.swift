import Observation
import OSLog
import UIKit

/// A single, finite handoff window for user-started monitoring. Never renews
/// itself in the background and never represents a continued-processing grant.
@MainActor
@Observable
final class AgentMonitoringGraceWindow {
    private(set) var isActive = false
    @ObservationIgnored private var identifier = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var didEnterBackground = false
    @ObservationIgnored private var onEnd: (@MainActor () -> Void)?
    private static let log = Logger(subsystem: "Hive", category: "AgentMonitoring.handoff")

    func begin(onEnd: @escaping @MainActor () -> Void) {
        guard !isActive, UIApplication.shared.applicationState == .active else { return }
        self.onEnd = onEnd
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Hive agent monitoring handoff"
        ) { [weak self] in
            // UIKit calls this on the main thread. Release the assertion before
            // returning; do not wait for networking or another task to finish.
            MainActor.assumeIsolated { self?.end(reason: "iOS expiration") }
        }
        isActive = identifier != .invalid
        Self.log.info("Brief background assertion available: \(self.isActive)")
        if !isActive { self.onEnd = nil }
    }

    func enteredBackground() {
        guard isActive, !didEnterBackground else { return }
        didEnterBackground = true
        // Use the real assertion's lifetime. iOS calls the expiration handler;
        // an arbitrary client timer must not discard execution it still permits.
        Self.log.info("Brief background window started; waiting for iOS expiration")
    }

    func enteredForeground() {
        // A fresh working heartbeat can request a new foreground handoff after
        // return. Never renew an assertion from a background timer or heartbeat.
        if didEnterBackground { end(reason: "foreground resumed") }
    }

    func end(reason: String = "handoff finished") {
        didEnterBackground = false
        guard identifier != .invalid else { return }
        let previous = identifier
        identifier = .invalid
        isActive = false
        UIApplication.shared.endBackgroundTask(previous)
        Self.log.info("Brief background window ended: \(reason, privacy: .public)")
        let callback = onEnd
        onEnd = nil
        callback?()
    }
}
