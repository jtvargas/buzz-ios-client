import BackgroundTasks
import Foundation
import Observation
import OSLog
import UIKit

/// Background execution is an optional capability of an already-running monitor.
/// A successful submission alone is never treated as an execution grant.
@MainActor
@Observable
final class AgentMonitoringRuntime {
    static let duration: TimeInterval = 30 * 60

    private(set) var isActive = false
    private(set) var isRequesting = false
    private(set) var explanation = "Updates pause when Hive leaves the foreground."
    @ObservationIgnored let graceWindow = AgentMonitoringGraceWindow()

    var hasExecutionTime: Bool { isActive || graceWindow.isActive }

    @ObservationIgnored private var identifier: String?
    @ObservationIgnored private var task: BGContinuedProcessingTask?
    @ObservationIgnored private var requestLoop: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration: UUID?
    @ObservationIgnored private var lastDirectRequest: ContinuousClock.Instant?
    private static let log = Logger(subsystem: "Hive", category: "AgentMonitoring.runtime")

    func request(
        immediately: Bool = false,
        expired: @escaping @MainActor () -> Void,
        windowEnded: @escaping @MainActor () -> Void
    ) {
        guard !isActive, UIApplication.shared.applicationState == .active else { return }
        graceWindow.begin(onEnd: windowEnded)
        if isRequesting {
            // Explicit retries can replace a pending request. Coalesce rapid
            // retries so they do not create a burst of scheduler submissions.
            guard immediately else { return }
            if let lastDirectRequest, lastDirectRequest.duration(to: .now) < .seconds(5) { return }
            requestLoop?.cancel()
            cancelPendingRequest()
        }
        let generation = UUID()
        requestGeneration = generation
        isRequesting = true
        explanation = "Requesting longer background monitoring. Updates already work while Hive is open."
        if immediately {
            lastDirectRequest = .now
            do { try submit(expired: expired) } catch {
                submissionFailed(error)
                return
            }
        }
        requestLoop = Task { [weak self] in
            guard let self else { return }
            await waitForLaunch(generation: generation, immediately: immediately, expired: expired)
        }
    }

    private func waitForLaunch(
        generation: UUID, immediately: Bool, expired: @escaping @MainActor () -> Void
    ) async {
        // Allow foreground presentation to settle before asking the scheduler.
        // One retry handles a transient mismatch in its foreground-app list.
        for attempt in 1...2 {
            do {
                if !immediately || attempt > 1 {
                    try await Task.sleep(for: .seconds(attempt == 1 ? 1 : 2))
                    guard requestGeneration == generation, !Task.isCancelled else { return }
                    guard UIApplication.shared.applicationState == .active else {
                        markUnavailable("Background monitoring unavailable. Hive retries after reopening.")
                        return
                    }
                    try submit(expired: expired)
                }
                try await Task.sleep(for: .seconds(5))
                guard requestGeneration == generation, !Task.isCancelled, !isActive else { return }
                Self.log.notice("Submission received no launch callback; attempt \(attempt)")
                cancelPendingRequest()
            } catch is CancellationError {
                return
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                submissionFailed(error)
                return
            }
        }
        guard requestGeneration == generation else { return }
        markUnavailable("iOS didn't start background monitoring. Hive retries automatically while agents are working.")
    }

    private func submit(expired: @escaping @MainActor () -> Void) throws {
        let prefix = Bundle.main.bundleIdentifier ?? "com.jtvargas.hive"
        let identifier = "\(prefix).agent-monitor.\(UUID().uuidString)"
        self.identifier = identifier
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.identifier == identifier,
                      let continued = task as? BGContinuedProcessingTask else {
                    // A cancelled attempt can arrive after its replacement. It owns
                    // no work and must never attach to the current monitoring session.
                    task.setTaskCompleted(success: true)
                    return
                }
                self.task = continued
                continued.progress.totalUnitCount = Int64(Self.duration)
                continued.expirationHandler = {
                    Task { @MainActor [weak self] in
                        guard self?.identifier == identifier else { return }
                        expired()
                    }
                }
                self.isActive = true
                self.graceWindow.end()
                self.isRequesting = false
                self.explanation = "Background monitoring active. iOS may still interrupt it."
                self.requestLoop?.cancel()
                self.requestLoop = nil
                Self.log.info("Background execution granted")
            }
        }
        guard registered else { throw RuntimeError.unavailable }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Hive · Agent monitoring", subtitle: "30-minute monitoring session"
        )
        request.strategy = .fail
        Self.log.info("Submitting background execution request")
        try BGTaskScheduler.shared.submit(request)
    }

    func enteredBackground() {
        graceWindow.enteredBackground()
        guard !isActive else { return }
        // Preserve a request already submitted in the foreground. Its callback
        // deadline still applies, and the real UIKit assertion covers the handoff.
        guard identifier == nil else { return }
        requestLoop?.cancel()
        requestLoop = nil
        requestGeneration = nil
        cancelPendingRequest()
        markUnavailable("Background monitoring unavailable. Hive retries automatically after reopening.")
    }

    private func submissionFailed(_ error: Error) {
        Self.log.error("Submission failed: \(error.localizedDescription, privacy: .public)")
        cancelPendingRequest()
        markUnavailable("iOS couldn't start background monitoring. Hive retries while agents are working.")
    }

    private func cancelPendingRequest() {
        guard task == nil else { return }
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
    }

    private func markUnavailable(_ message: String) {
        isRequesting = false
        explanation = message
        requestLoop = nil
        requestGeneration = nil
    }

    func report(elapsed: TimeInterval, agentCount: Int) {
        task?.progress.completedUnitCount = min(Int64(elapsed), Int64(Self.duration) - 1)
        task?.updateTitle(
            "Hive · Agent monitoring",
            subtitle: "\(agentCount) \(agentCount == 1 ? "agent" : "agents") working · Monitoring time"
        )
    }

    func finish(success: Bool) {
        requestLoop?.cancel()
        requestLoop = nil
        requestGeneration = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        lastDirectRequest = nil
        identifier = nil
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
        task = nil
        isActive = false
        graceWindow.end()
        isRequesting = false
        explanation = "Updates pause when Hive leaves the foreground."
    }

    enum RuntimeError: Error { case unavailable }
}
