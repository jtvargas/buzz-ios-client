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
    @ObservationIgnored private var deadline: Task<Void, Never>?
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
        guard isActive, deadline == nil else { return }
        Self.log.info("Brief background window started; maximum 20 seconds")
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.end(reason: "20-second limit")
        }
    }

    func enteredForeground() {
        // Returning finishes this handoff. Another explicit send/retry can request
        // a new one; ordinary scene changes do not extend a background budget.
        if deadline != nil { end(reason: "foreground resumed") }
    }

    func end(reason: String = "handoff finished") {
        deadline?.cancel()
        deadline = nil
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
