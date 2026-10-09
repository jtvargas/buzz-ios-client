import Foundation
import HivePushKit
import NostrCore
import Testing
import UserNotifications

@Suite("Locally resolved push notifications")
struct PushNotificationTests {
    @Test("Channel messages and forum events preserve their exact target", arguments: [9, 45001, 45003])
    func exactTarget(kind: Int) async throws {
        let sender = try InMemorySigner()
        let event = try await pushMessage(
            sender: sender, content: " Real\nmessage ", kind: EventKind(rawValue: kind), timestamp: 123
        )
        let notification = try #require(PushNotification.build(
            events: [event], community: pushCommunity(), selfPubkey: "reader"
        ))
        #expect(notification.title == "Test community")
        #expect(notification.body == "Real message")
        #expect(notification.target.communityID == "community")
        #expect(notification.target.channelID == "channel")
        #expect(notification.target.eventID == event.id)
        #expect(notification.target.createdAt == 123)
        #expect(notification.target.rootID == nil)
    }

    @Test("Reply roots remain separate from the message to focus")
    func threadTarget() async throws {
        let sender = try InMemorySigner()
        let rootID = String(repeating: "a", count: 64)
        let event = try await pushMessage(sender: sender, tags: [
            ["h", "channel"], ["e", rootID, "", "root"],
            ["e", String(repeating: "b", count: 64), "", "reply"],
        ])
        let notification = try #require(PushNotification.build(
            events: [event], community: pushCommunity(), selfPubkey: "reader"
        ))
        #expect(notification.target.rootID == rootID)
        #expect(notification.target.eventID == event.id)
        #expect(PushNotificationTarget.decode(from: [
            PushNotificationTarget.userInfoKey: notification.target.userInfoValue,
        ]) == notification.target)
    }

    @Test("Own, forged, unroutable, blank, and unrelated events cannot displace a real message")
    func ineligibleCandidates() async throws {
        let sender = try InMemorySigner()
        let reader = try InMemorySigner()
        let valid = try await pushMessage(sender: sender, content: "Incoming", timestamp: 10)
        let own = try await pushMessage(sender: reader, timestamp: 20)
        let blank = try await pushMessage(sender: sender, content: " \n ", timestamp: 30)
        let unroutable = try await pushMessage(sender: sender, timestamp: 40, tags: [])
        let unrelated = try await pushMessage(sender: sender, kind: 7, timestamp: 50)
        let forged = NostrEvent(id: valid.id, pubkey: valid.pubkey, createdAt: 60,
                                kind: valid.kind, tags: valid.tags, content: "Tampered", sig: valid.sig)
        let notification = try #require(PushNotification.build(
            events: [forged, own, blank, unroutable, unrelated, valid],
            community: pushCommunity(), selfPubkey: try await reader.publicKey().hex
        ))
        #expect(notification.target.eventID == valid.id)
        #expect(notification.body == "Incoming")
        #expect(PushNotification.build(events: [forged], community: pushCommunity(), selfPubkey: "reader") == nil)
    }

    @Test("Coalesced results choose newest then lowest id, independent of order or duplicates")
    func deterministicSelection() async throws {
        let sender = try InMemorySigner()
        let older = try await pushMessage(sender: sender, timestamp: 1)
        let first = try await pushMessage(sender: sender, content: "One", timestamp: 2)
        let second = try await pushMessage(sender: sender, content: "Two", timestamp: 2)
        let expectedID = min(first.id, second.id)
        for events in [[older, first, second], [second, first, older, second]] {
            let notification = try #require(PushNotification.build(
                events: events, community: pushCommunity(), selfPubkey: "reader"
            ))
            #expect(notification.target.eventID == expectedID)
        }
    }

    @Test("Rich overlays never expose JSON or link to an invisible timeline event")
    func richOverlay() async throws {
        let sender = try InMemorySigner()
        let message = try await pushMessage(sender: sender, content: "Plain message", timestamp: 1)
        let overlay = try await pushMessage(
            sender: sender, content: #"{"type":"doc","content":[]}"#, kind: 40002,
            timestamp: 2, tags: [["h", "channel"], ["e", message.id]]
        )
        let notification = try #require(PushNotification.build(
            events: [overlay, message], community: pushCommunity(), selfPubkey: "reader"
        ))
        #expect(notification.target.eventID == message.id)
        #expect(notification.body == message.content)
        #expect(PushNotification.build(events: [overlay], community: pushCommunity(), selfPubkey: "reader") == nil)
    }

    @Test("Grouping isolates the same channel id in different communities")
    func communityGrouping() async throws {
        let event = try await pushMessage(sender: InMemorySigner())
        let first = try #require(PushNotification.build(
            events: [event], community: pushCommunity(id: "one"), selfPubkey: "reader"
        ))
        let second = try #require(PushNotification.build(
            events: [event], community: pushCommunity(id: "two"), selfPubkey: "reader"
        ))
        #expect(first.threadIdentifier != second.threadIdentifier)
    }

    @Test("Applying a resolution preserves system fields and does not mutate the original")
    func systemContent() async throws {
        let event = try await pushMessage(sender: InMemorySigner(), content: "Resolved message")
        let notification = try #require(PushNotification.build(
            events: [event], community: pushCommunity(), selfPubkey: "reader"
        ))
        let original = UNMutableNotificationContent()
        original.body = "Reconnect to your relay now"
        original.badge = 3
        original.categoryIdentifier = "category"
        original.userInfo = [
            "aps": ["mutable-content": 1],
            PushNotificationTarget.userInfoKey: ["eventID": "untrusted"],
        ]
        let result = notification.applying(to: original)
        #expect(result.body == "Resolved message")
        #expect(result.badge == 3)
        #expect(result.categoryIdentifier == "category")
        #expect(result.threadIdentifier == notification.threadIdentifier)
        #expect(PushNotificationTarget.decode(from: result.userInfo) == notification.target)
        #expect(original.body == "Reconnect to your relay now")
    }

    @Test("Empty results do not manufacture a notification")
    func emptyResults() {
        #expect(PushNotification.build(events: [], community: pushCommunity(), selfPubkey: "reader") == nil)
    }
}
