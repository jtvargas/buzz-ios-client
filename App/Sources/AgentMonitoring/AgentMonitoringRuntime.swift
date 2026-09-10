import BackgroundTasks
import Foundation

/// Owns one explicitly requested, finite monitoring window. Progress describes
/// elapsed monitoring time, never an estimate of an agent's completion.
@MainActor
final class AgentMonitoringRuntime {
    static let duration: TimeInterval = 30 * 60

    private var identifier: String?
    private var task: BGContinuedProcessingTask?

    func request(granted: @escaping @MainActor () -> Void, expired: @escaping @MainActor () -> Void) throws {
        let prefix = Bundle.main.bundleIdentifier ?? "com.jtvargas.hive"
        let identifier = "\(prefix).agent-monitor.\(UUID().uuidString)"
        self.identifier = identifier
        // An exact handler for each request avoids conflating a late launch from a
        // cancelled session with a new session. Info.plist permits this prefix.
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.identifier == identifier,
                      let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
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
                granted()
            }
        }
        guard registered else { throw RuntimeError.unavailable }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Hive · Agent monitoring",
            subtitle: "30-minute monitoring session"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            self.identifier = nil
            throw error
        }
    }

    func report(elapsed: TimeInterval, agentCount: Int) {
        task?.progress.completedUnitCount = min(Int64(elapsed), Int64(Self.duration) - 1)
        task?.updateTitle(
            "Hive · Agent monitoring",
            subtitle: "\(agentCount) \(agentCount == 1 ? "agent" : "agents") working · Monitoring time"
        )
    }

    func finish(success: Bool) {
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
        task = nil
    }

    enum RuntimeError: Error { case unavailable }
}
