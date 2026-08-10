import BuzzKit
@testable import Hive
import Testing

/// Where a tapped banner takes the reader.
///
/// This decision had **no coverage at all** until 2026-08-09, which is how a direct message's
/// grouping rule ended up deciding its navigation for as long as it did. The point of a suite
/// here is that the routing is a pure function of an ``ActivityEntry`` — no view, no store, no
/// navigation stack — so the thing that actually went wrong is cheap to pin.
@Suite("In-app notification routing")
struct InAppNotificationRouteTests {
    private static func entry(
        channelID: String? = "channel-1",
        isDirectMessage: Bool = false,
        rootID: String? = nil,
        messageID: String = "message-1",
        createdAt: Int64 = 1_786_311_600
    ) -> ActivityEntry {
        ActivityEntry(
            id: rootID ?? messageID,
            category: .mention,
            categories: [.mention],
            channelID: channelID,
            channelName: "ios-development",
            isDirectMessage: isDirectMessage,
            latest: ActivityEvent(
                id: messageID,
                pubkey: "author",
                authorName: "Maya Chen",
                authorPicture: nil,
                kind: 9,
                content: "the build is up",
                createdAt: createdAt
            ),
            eventCount: 1,
            unreadCount: 1,
            rootID: rootID
        )
    }

    @Test("a reply goes to its thread")
    func replyRoutesToThread() {
        let notification = InAppNotification(entry: Self.entry(rootID: "root-1"))
        #expect(notification.location == .thread(channelID: "channel-1", rootID: "root-1"))
    }

    @Test("a reply inside a direct message goes to its thread too")
    func replyInDirectMessageRoutesToThread() {
        // The regression this suite was written for. `isDirectMessage` used to be tested
        // first and returned `.channel`, discarding a root it already held — so a tap landed
        // on the DM's timeline, which is a page a reply is excluded from by construction.
        let notification = InAppNotification(entry: Self.entry(isDirectMessage: true, rootID: "root-1"))
        #expect(notification.location == .thread(channelID: "channel-1", rootID: "root-1"))
    }

    @Test("a top-level message goes to its channel")
    func topLevelRoutesToChannel() {
        #expect(InAppNotification(entry: Self.entry()).location == .channel("channel-1"))
        let dm = InAppNotification(entry: Self.entry(isDirectMessage: true))
        #expect(dm.location == .channel("channel-1"))
    }

    @Test("the route aims at the message, carrying the timestamp the walk needs")
    func routeFocusesTheMessage() {
        let notification = InAppNotification(entry: Self.entry(messageID: "message-9", createdAt: 42))
        // Both halves matter: the id is what is scrolled to and washed, and `sentAt` is what
        // lets the history walk decide the message is not on this surface without reading to
        // the beginning of the channel. See ``ConversationFocus``.
        #expect(notification.route.focus == ConversationFocus(messageID: "message-9", sentAt: 42))
    }

    @Test("the location names a place and never a message")
    func locationIsFreeOfTheMessage() {
        // The invariant behind keeping `focus` off `location`. `location` is also asked "is
        // the reader already looking at this?" against `RecentPlaces.location(path:
        // openedThread:)`, which knows a channel and a thread and nothing about which message
        // is on screen. Two replies in one thread must therefore be one place, or every
        // banner would survive arriving at its own destination.
        let first = InAppNotification(entry: Self.entry(rootID: "root-1", messageID: "message-1"))
        let second = InAppNotification(entry: Self.entry(rootID: "root-1", messageID: "message-2"))
        #expect(first.location == second.location)
        #expect(first.route.focus != second.route.focus)
    }

    @Test("a banner is suppressed only by the place it would open")
    func visibilityFollowsTheLocation() {
        let reply = InAppNotification(entry: Self.entry(rootID: "root-1"))
        // Standing in the channel is not standing in the thread — the reply is not on that
        // page at all, so the banner is still the only way the reader learns about it.
        #expect(!reply.location.isVisible(in: .channel("channel-1")))
        #expect(reply.location.isVisible(in: .thread(channelID: "channel-1", rootID: "root-1")))
    }
}
