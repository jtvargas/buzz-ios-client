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
    /// The one message this arrival was about, when it names one.
    ///
    /// Deliberately **not** folded into ``location``. That value answers a second question —
    /// *is the reader already looking at this?* — by comparing against
    /// ``RecentPlaces/location(path:openedThread:)``, which knows a channel and a thread and
    /// has no idea which message is on screen. A message id inside it would make every
    /// comparison fail and every banner survive its own destination.
    ///
    /// `nil` for an arrival that names a place rather than a message: a recent place, or an
    /// App Intent asking for a thread.
    var focus: ConversationFocus?
}

/// One foreground banner, derived from the Activity feed's already-classified event.
struct InAppNotification: Hashable, Identifiable {
    let entry: ActivityEntry

    var id: String { entry.latest.id }
    var conversationID: String { entry.id }

    /// The surface this message actually lives on.
    ///
    /// A root means a thread, **including inside a direct message**. That last part used to be
    /// the other way round — `isDirectMessage` was tested first and sent every DM to its own
    /// timeline — and it was a grouping rule that had wandered into a navigation decision. The
    /// Activity feed keys a DM's *row* on the channel so one conversation stays one row
    /// (``BuzzEventStore/ActivityFeedRead/Candidate/conversationID``); where a *tap* lands is a
    /// different question, and the answer to it is wherever the message can be seen. A reply
    /// is excluded from its channel's page by BuzzKit's timeline query, so a DM opened at its
    /// timeline is a screen that message can never appear on — and with ``focus`` set, one the
    /// landing would page all the way back through looking for it.
    var location: InAppNotificationLocation {
        if let channelID = entry.channelID, let rootID = entry.rootID {
            return .thread(channelID: channelID, rootID: rootID)
        }
        return .channel(entry.channelID ?? "")
    }

    /// This banner as a navigation request, aimed at the message rather than the room.
    ///
    /// The same landing search performs: the surface opens, walks history back until the
    /// message is loaded, scrolls to it and washes it once (``View/messageFocusHighlight(_:)``).
    /// Both fields ``ConversationFocus`` needs are already on the event, and the timestamp is
    /// the half that makes the walk terminate — see that type.
    var route: InAppNotificationRoute {
        InAppNotificationRoute(
            location: location,
            fallbackChannel: fallbackChannel,
            focus: ConversationFocus(messageID: entry.latest.id, sentAt: entry.latest.createdAt)
        )
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
