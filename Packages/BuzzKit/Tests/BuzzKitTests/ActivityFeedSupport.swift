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

    /// Registers `agent` in the relay's agent directory — one of the two authorities that
    /// make an author an agent (`Directory.swift:158`).
    static func agentProfile(_ agent: Fixture, name: String, at seconds: Int64) throws -> NostrEvent {
        try agent.event(
            .agentProfile,
            #"{"display_name":"\#(name)","respond_to":"anyone","channel_ids":[]}"#,
            at: seconds
        )
    }

    /// A channel roster carrying the `bot` role for `bots` — the *other* authority, and the
    /// one that actually applies on JT's relay, where agents are channel members with a role
    /// rather than entries in a directory.
    static func members(
        _ relay: Fixture,
        _ channel: String,
        people: [String],
        bots: [String] = [],
        at seconds: Int64
    ) throws -> NostrEvent {
        let tags = [["d", channel]]
            + people.map { ["p", $0] }
            // Four elements, because that is what the relay signs: the role sits in the
            // petname slot with an empty relay hint ahead of it.
            + bots.map { ["p", $0, "", "bot"] }
        return try relay.event(.groupMembers, "", tags: tags, at: seconds)
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
