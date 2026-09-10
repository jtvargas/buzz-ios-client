import SwiftUI

struct ExperimentalSettingsCard: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = environment.settings
        AccountCard(
            title: "Live agent activity",
            subtitle: "Show a Live Activity when an agent starts working while Hive is open."
        ) {
            EmptyView()
        } content: {
            AccountFieldRow(label: "ON THIS PHONE") {
                Toggle("Experimental", isOn: $settings.experimentalAgentMonitoring)
                    .font(.hive(.body))
                    .onChange(of: settings.experimentalAgentMonitoring) { _, enabled in
                        environment.applyExperimentalMonitoring(enabled)
                    }
            }
            if settings.experimentalAgentMonitoring {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(environment.agentMonitor.status)
                        .font(.hive(.subheadline, weight: .medium))
                    AgentMonitoringAccessView()
                    HStack {
                        NavigationLink("View agents") { AgentMonitoringRosterView() }
                        Spacer()
                        if environment.agentMonitor.isMonitoring || environment.agentMonitor.isStarting {
                            Button("Stop monitoring") { environment.agentMonitor.requestStop() }
                        } else if !environment.agentMonitor.isArmed {
                            Button("Enable next activity") {
                                environment.armExperimentalMonitoringIfEnabled(force: true)
                            }
                        }
                    }
                    .font(.hive(.footnote, weight: .medium))
                    .disabled(environment.agentMonitor.isStopping)
                    Text("Enabling waits for a fresh working indicator from an agent. "
                         + "Sending a message alone won't show a card. "
                         + "Once work is detected while Hive is open, a session lasts up to 30 minutes. "
                         + "Tracks joined conversations in the current community. "
                         + "iOS may interrupt monitoring or show its own progress card. "
                         + "Names and channel labels appear on the Lock Screen.")
                        .font(.hive(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Heartbeat silence is not confirmed completion. A stale card says monitoring is paused.")
                        .font(.hive(.footnote))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }
}
