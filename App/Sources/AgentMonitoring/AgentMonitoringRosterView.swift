import SwiftUI

struct AgentMonitoringRosterView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(environment.agentMonitor.status)
                if let end = environment.agentMonitor.sessionEndsAt {
                    LabeledContent("Session ends", value: end, format: .dateTime.hour().minute())
                }
                if let update = environment.agentMonitor.lastUpdate {
                    LabeledContent("Last update", value: update, format: .dateTime.hour().minute().second())
                }
            }
            Section("Conversations with recent agent activity") {
                ForEach(environment.agentMonitor.roster) { row in
                    Button {
                        environment.openMonitoredConversation(row)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(row.name) is working…")
                                .font(.hive(.body, weight: .medium))
                            Text(row.context)
                                .font(.hive(.caption))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .tint(.primary)
                }
                if environment.agentMonitor.roster.isEmpty {
                    Text("No recent agent activity received")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("An agent can appear in multiple conversations. The Lock Screen counts each agent once. "
                     + "Activity expires after missed heartbeats; this does not confirm that a task succeeded.")
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
                Button("Stop monitoring") { environment.agentMonitor.requestStop() }
                    .disabled(!environment.agentMonitor.isMonitoring && !environment.agentMonitor.isStarting)
            }
        }
        .navigationTitle("Agent activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
