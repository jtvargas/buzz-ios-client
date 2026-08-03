@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Shared fixtures for the Activity feed suites.
///
/// At file scope rather than inside a suite because two suites use them, and duplicating a
/// fixture is how two tests quietly stop testing the same thing.
enum ActivityFixtures {
    // MARK: - Fixtures

    /// A channel's metadata, published by the relay identity. `type` is the relay's own
    /// `["t", …]` — `dm` is what makes a row title itself by person rather than by channel.
    static func meta(
        _ relay: Fixture,
        _ id: String,
        name: String,
        type: String? = nil,
        at seconds: Int64
    ) throws -> NostrEvent {
        var tags: [[String]] = [["d", id]]
        if let type { tags.append(["t", type]) }
        return try relay.event(.groupMetadata, #"{"name":"\#(name)"}"#, tags: tags, at: seconds)
    }

    /// A channel message, optionally naming people and optionally a reply in a thread.
    static func message(
        _ author: Fixture,
        _ text: String,
        in channel: String,
        mentions: [String] = [],
        replyTo root: String? = nil,
        at seconds: Int64
    ) throws -> NostrEvent {
        var tags = [["h", channel]]
        if let root { tags.append(["e", root, "", "reply"]) }
        tags += mentions.map { ["p", $0] }
        return try author.event(.channelMessage, text, tags: tags, at: seconds)
    }

    /// A store holding one channel the identity may see. Every test needs this pair —
    /// the feed gates on `channel_access` exactly as the sidebar does, so a channel the
    /// sidebar would not show contributes nothing here either.
    static func openStore(
        _ database: TempDatabase,
        identity: String,
        channels: [String]
    ) async throws -> BuzzEventStore {
        let store = try database.open()
        for channel in channels {
            try await store.markChannelAccess(identity: identity, channel: channel, state: .active)
        }
        return store
    }
}
