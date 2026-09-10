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
                    Text("Updates can continue for up to 20 seconds after leaving Hive. iOS may end this sooner.")
                        .font(.hive(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(monitor.runtime.explanation)
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !monitor.runtime.isActive {
                    Button(
                        monitor.runtime.isRequesting
                            ? "Requesting background monitoring…" : "Retry background monitoring"
                    ) {
                        monitor.retryBackgroundAccess(immediately: true)
                    }
                    .font(.hive(.footnote, weight: .medium))
                    .disabled(monitor.runtime.isRequesting || monitor.isStopping)
                }
            }
        }
    }
}
