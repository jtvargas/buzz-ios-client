import BuzzKit
import Foundation

extension AppEnvironment {
    func armExperimentalMonitoringIfEnabled(force: Bool = false) {
        guard settings.experimentalAgentMonitoring,
              force || !agentMonitor.hasAttemptedStart,
              phase == .running,
              let engine, let store, let community = communities.active,
              community.id == sessionCommunityID else { return }
        agentMonitor.arm(
            engine: engine, store: store, community: community, selfPubkey: selfPubkeyHex
        )
    }

    func applyExperimentalMonitoring(_ enabled: Bool) {
        if enabled {
            armExperimentalMonitoringIfEnabled(force: true)
        } else {
            // Cancel the trigger synchronously so an in-flight relay read cannot
            // start a card before the asynchronous cleanup gets to run.
            agentMonitor.disarm()
            Task {
                await agentMonitor.stop()
                await agentMonitor.writer.removeOrphans()
                // Honor a rapid off/on toggle after the old session's cleanup.
                if settings.experimentalAgentMonitoring { armExperimentalMonitoringIfEnabled(force: true) }
            }
        }
    }

    func openMonitoredConversation(_ row: AgentActivityAttributes.AgentRow) {
        guard let community = communities.active else { return }
        opensAgentMonitorAfterSettings = false
        showsAgentMonitor = false
        showsSettings = false
        if let root = row.threadID {
            navigator.request(.thread(channelID: row.channelID, rootID: root))
        } else {
            navigator.request(.conversation(EntityID(community: community.id, native: row.channelID)))
        }
    }

    func handleAgentMonitoringURL(_ url: URL) -> Bool {
        guard url.scheme == "buzz", url.host == "agent-monitor",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "community" })?.value,
              let communityID = UUID(uuidString: value) else { return false }
        // An old lock-screen card cannot route an identifier into another community.
        guard communities.activeID == communityID else {
            notice = AppNotice(title: "Another community", message: "Open the activity's community in Hive first.")
            return true
        }
        if let channel = items.first(where: { $0.name == "channel" })?.value, !channel.isEmpty {
            opensAgentMonitorAfterSettings = false
            showsAgentMonitor = false
            showsSettings = false
            if let root = items.first(where: { $0.name == "thread" })?.value, !root.isEmpty {
                navigator.request(.thread(channelID: channel, rootID: root))
            } else {
                navigator.request(.conversation(EntityID(community: communityID, native: channel)))
            }
        } else {
            if showsSettings {
                opensAgentMonitorAfterSettings = true
                showsSettings = false
            } else {
                showsAgentMonitor = true
            }
        }
        return true
    }

    func didDismissSettingsForMonitoring() {
        guard opensAgentMonitorAfterSettings else { return }
        opensAgentMonitorAfterSettings = false
        showsAgentMonitor = true
    }
}
