import Observation
import SwiftUI

/// Why a message-link landing could not be completed.
///
/// Stage 1 can only reach notInStore. The remaining cases are declared now so later history
/// and relay stages extend one failure vocabulary instead of growing competing surfaces.
enum MessageLandingFailure: Equatable {
    /// The channel is available, but the requested row is not loaded on this device yet.
    case notInStore
    /// The event exists locally, but its channel tag does not match the link's channel.
    case channelMismatch
    /// A store or relay read could not complete before its timeout or connection failed.
    case offlineOrTimedOut
    /// The relay completed the lookup but returned no accessible event.
    case relayReturnedNothing
    /// The event is a thread reply, which stage 1 cannot open on the channel timeline.
    case messageIsInThread
}

/// A message link waiting for the timeline that owns its channel to consume it.
struct MessageLanding: Equatable, Hashable, Identifiable {
    let channelID: String
    let eventID: String
    let threadRootID: String?

    var id: String { "\(channelID):\(eventID)" }
}

/// Carries a message-link landing from a rich-text row to the navigation surface.
///
/// The router is independent of navigation state. ConversationRoute deduplicates an
/// already-open channel by leaving the path unchanged, but a message link still needs to
/// land in that existing timeline. The owning ChannelTimelineView reads this value,
/// performs its synchronous Stage 1 landing, and clears it only after the work.
@MainActor
@Observable
final class MessageLandingRouter {
    /// The next landing request. The owning timeline consumes and clears it after handling it.
    var pendingLanding: MessageLanding?
    /// A reader-facing failure, surfaced by the root navigation surface.
    var failure: String?

    func open(channelID: String, eventID: String, threadRootID: String?) {
        failure = nil
        pendingLanding = MessageLanding(
            channelID: channelID,
            eventID: eventID,
            threadRootID: threadRootID
        )
    }

    func fail(_ reason: MessageLandingFailure) {
        pendingLanding = nil
        failure = Self.message(for: reason)
    }

    static func message(for reason: MessageLandingFailure) -> String {
        switch reason {
        case .notInStore:
            return "That message is not loaded in this conversation yet."
        case .channelMismatch:
            return "That link points to a different channel."
        case .offlineOrTimedOut:
            return "Couldn’t load that message. Check your connection."
        case .relayReturnedNothing:
            return "That message is unavailable. It may have been deleted, or you may not be in that channel."
        case .messageIsInThread:
            return "That message is in a thread. Opening thread links is coming next."
        }
    }
}

extension EnvironmentValues {
    /// Optional because previews and isolated message surfaces need no navigation owner.
    @Entry var messageLandingRouter: MessageLandingRouter?
}
