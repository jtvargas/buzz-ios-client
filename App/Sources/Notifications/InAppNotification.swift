import BuzzKit
import Foundation

/// A destination the banner can open through the Home tab's navigation stack.
enum InAppNotificationLocation: Hashable {
    case channel(String)
    case thread(channelID: String, rootID: String)

    var channelID: String {
        switch self {
        case let .channel(channelID), let .thread(channelID, _): channelID
        }
    }

    func isVisible(in visible: InAppNotificationLocation?) -> Bool {
        self == visible
    }
}

/// The navigation value carried until ``ChannelListView`` consumes it.
struct InAppNotificationRoute: Hashable {
    let location: InAppNotificationLocation
    let fallbackChannel: ChannelListRow
}

/// One foreground banner, derived from the Activity feed's already-classified event.
struct InAppNotification: Hashable, Identifiable {
    let entry: ActivityEntry

    var id: String { entry.latest.id }
    var conversationID: String { entry.id }

    var location: InAppNotificationLocation {
        if entry.isDirectMessage { return .channel(entry.channelID ?? "") }
        if let channelID = entry.channelID, let rootID = entry.rootID {
            return .thread(channelID: channelID, rootID: rootID)
        }
        return .channel(entry.channelID ?? "")
    }

    var route: InAppNotificationRoute {
        InAppNotificationRoute(location: location, fallbackChannel: fallbackChannel)
    }

    var qualifies: Bool {
        guard entry.channelID?.isEmpty == false else { return false }
        return entry.categories.contains(.mention) || entry.isDirectMessage || entry.rootID != nil
    }

    var context: String {
        if entry.isDirectMessage { return "New direct message" }
        let place = entry.channelName.isEmpty ? "a channel" : "#\(entry.channelName)"
        if entry.categories.contains(.mention) { return "Mentioned you in \(place)" }
        return "Replied in \(place)"
    }

    var accessibilityLabel: String {
        "\(entry.latest.authorName), \(context), \(entry.latest.content)"
    }

    private var fallbackChannel: ChannelListRow {
        ChannelListRow(
            id: entry.channelID ?? "",
            name: entry.channelName.isEmpty ? nil : entry.channelName,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: entry.latest.createdAt,
            lastMessageID: entry.latest.id,
            lastMessageSnippet: entry.latest.content,
            lastMessageAuthor: entry.latest.authorName,
            lastMessageAuthorPubkey: entry.latest.pubkey,
            channelType: entry.isDirectMessage ? "dm" : nil
        )
    }
}
