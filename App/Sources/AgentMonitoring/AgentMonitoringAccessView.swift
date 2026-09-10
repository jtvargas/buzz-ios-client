import SwiftUI

/// Separate from agent presence: receiving heartbeats does not prove that iOS
/// granted permission to keep receiving them after the app is backgrounded.
struct AgentMonitoringAccessView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let monitor = environment.agentMonitor
        if monitor.isMonitoring {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    monitor.runtime.isActive ? "Background monitoring active"
                        : monitor.runtime.graceWindow.isActive ? "Brief background window" : "Foreground only",
                    systemImage: monitor.runtime.isActive ? "checkmark.circle" : "iphone"
                )
                .font(.hive(.subheadline, weight: .medium))
                if monitor.runtime.graceWindow.isActive && !monitor.runtime.isActive {
                    Text("Updates continue for the background time iOS allows. iOS can end this window at any time.")
                        .font(.hive(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(monitor.runtime.explanation)
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !monitor.runtime.isActive {
                    Text(monitor.waitsForForegroundReturn
                         ? "Background execution ended. Reopen Hive to resume automatically when an agent is working."
                         : "Hive automatically retries while open when fresh agent activity is received.")
                        .font(.hive(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
