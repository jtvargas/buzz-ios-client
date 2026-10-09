import Foundation
import NostrCore
import UserNotifications

/// The exact event and conversation resolved locally, never supplied by APNs.
/// The timestamp lets a consumer page history to the message rather than merely
/// opening its channel. Thread identity is separate from notification grouping.
public struct PushNotificationTarget: Codable, Equatable, Sendable {
    public static let userInfoKey = "hivePushTarget"

    public let communityID: String
    public let channelID: String
    public let eventID: String
    public let createdAt: Int64
    public let rootID: String?

    public var userInfoValue: [String: Any] {
        var value: [String: Any] = [
            "communityID": communityID,
            "channelID": channelID,
            "eventID": eventID,
            "createdAt": createdAt,
        ]
        if let rootID { value["rootID"] = rootID }
        return value
    }

    /// Reads only the locally authored target, not fields of the reconnect payload.
    public static func decode(from userInfo: [AnyHashable: Any]) -> Self? {
        guard let value = userInfo[userInfoKey] as? [String: Any],
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// A single best-effort preview for one wake. No database, profile fetches, media
/// downloads, or persistence are required to construct it.
public struct PushNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let threadIdentifier: String
    public let target: PushNotificationTarget

    /// Selects the newest authentic incoming message; ties use ascending event id
    /// so relay ordering cannot change which message a coalesced wake presents.
    ///
    /// Kind 40002 is a rich-content overlay in Hive, not a timeline message. Its
    /// referenced kind-9 message supplies the preview and exact navigation target
    /// when present in the query results. An overlay alone must not link to an
    /// event that the app's timeline cannot display or expose its JSON as prose.
    public static func build(
        events: [NostrEvent],
        community: PushCommunitySnapshot,
        selfPubkey: String
    ) -> Self? {
        var newest: NostrEvent?
        var preview = ""
        for event in events {
            guard [9, 45001, 45003].contains(event.kind.rawValue),
                  event.pubkey != selfPubkey,
                  event.groupID?.isEmpty == false,
                  event.isValid
            else { continue }
            if let newest,
               event.createdAt < newest.createdAt ||
               (event.createdAt == newest.createdAt && event.id >= newest.id) {
                continue
            }
            let body = event.content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !body.isEmpty else { continue }
            newest = event
            preview = body.count > 180 ? String(body.prefix(177)) + "…" : body
        }
        guard let event = newest, let channelID = event.groupID else { return nil }
        return Self(
            title: community.name,
            body: preview,
            // Length-prefixing avoids collisions even if a channel id contains a separator.
            threadIdentifier: "\(community.communityID.count):\(community.communityID)\(channelID)",
            target: PushNotificationTarget(
                communityID: community.communityID,
                channelID: channelID,
                eventID: event.id,
                createdAt: event.createdAt,
                rootID: event.threadReference.rootID
            )
        )
    }

    /// Keeps sound, badge, and other system fields, replacing only presentation
    /// and the locally resolved target. The input content is never mutated.
    public func applying(to original: UNNotificationContent) -> UNNotificationContent {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        content.title = title
        content.subtitle = ""
        content.body = body
        content.threadIdentifier = threadIdentifier
        content.userInfo[PushNotificationTarget.userInfoKey] = target.userInfoValue
        return content
    }
}
