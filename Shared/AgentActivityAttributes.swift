import ActivityKit
import Foundation

struct AgentActivityAttributes: ActivityAttributes, Sendable {
    let communityID: String
    let communityName: String

    struct ContentState: Codable, Hashable, Sendable {
        var rows: [AgentRow]
        var agentCount: Int
        var scopeCount: Int
        var status: Status
        var updatedAt: Date
        var sessionEndsAt: Date
        // Optional for cards created by an earlier build of this prototype.
        var isForegroundOnly: Bool?
    }

    struct AgentRow: Codable, Hashable, Identifiable, Sendable {
        let pubkey: String
        let name: String
        let initials: String
        let channelID: String
        let channelName: String
        let threadID: String?

        var id: String { "\(pubkey):\(channelID):\(threadID ?? "")" }
        var context: String { threadID == nil ? channelName : "\(channelName) · Thread" }
    }

    enum Status: String, Codable, Sendable {
        case working, waiting, reconnecting, paused, ended

        var label: String {
            switch self {
            case .working: "Working"
            case .waiting: "Waiting for agent activity"
            case .reconnecting: "Reconnecting to the relay"
            case .paused: "Monitoring paused"
            case .ended: "Monitoring ended"
            }
        }
    }

    static func link(communityID: String, row: AgentRow? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "buzz"
        components.host = "agent-monitor"
        components.queryItems = [URLQueryItem(name: "community", value: communityID)]
        if let row {
            components.queryItems?.append(URLQueryItem(name: "channel", value: row.channelID))
            if let threadID = row.threadID {
                components.queryItems?.append(URLQueryItem(name: "thread", value: threadID))
            }
        }
        return components.url
    }
}
