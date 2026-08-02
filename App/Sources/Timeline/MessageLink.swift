import Foundation

/// Builds the `buzz://message` links shared by the desktop and mobile clients.
///
/// The query item order is part of the desktop format, so channel and message come first;
/// the thread root is appended only for a reply. `URLComponents` owns escaping because these
/// values are event data rather than URL-safe literals.
enum MessageLink {
    static func url(channelID: String, messageID: String, threadRootID: String?) -> URL? {
        guard !channelID.isEmpty, !messageID.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "buzz"
        components.host = "message"
        components.queryItems = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "id", value: messageID),
        ]
        if let threadRootID, !threadRootID.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "thread", value: threadRootID))
        }
        return components.url
    }
}
