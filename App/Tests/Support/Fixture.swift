import Foundation
import NostrCore

/// Builds signed events for the view-model tests. One key per instance, so
/// authorship is stable across a fixture's events.
///
/// A minimal copy of BuzzKit's own test `Fixture` (the repo's duplicate-the-harness
/// precedent, spec §as-built note). It touches only NostrCore's public signing
/// path, so a plain `import NostrCore` — not `@testable` — suffices, and it is
/// exactly the signing a real event off the wire went through.
struct Fixture {
    let key: PrivateKey

    init() throws {
        key = try PrivateKey()
    }

    var pubkey: String { key.publicKey.hex }

    func event(
        _ kind: EventKind,
        _ content: String = "",
        tags: [[String]] = [],
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: kind,
            content: content,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            with: key
        )
    }

    /// A kind-9 channel message scoped to a group by its `h` tag.
    func message(
        _ content: String,
        in channel: String = "room-1",
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try event(.channelMessage, content, tags: [["h", channel]], at: seconds)
    }

    /// A kind-39000 relay-signed channel-metadata event, addressable by its `d`.
    /// (In production the relay authors these; a fixture key stands in for the
    /// tests, and the store projects it into the `channel` table all the same.)
    func channelMetadata(
        _ channel: String,
        name: String,
        about: String? = nil,
        picture: String? = nil,
        isPrivate: Bool = false,
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        var content: [String: String] = ["name": name]
        if let about { content["about"] = about }
        if let picture { content["picture"] = picture }
        let data = try JSONSerialization.data(withJSONObject: content)
        let json = String(bytes: data, encoding: .utf8) ?? "{}"
        var tags: [[String]] = [["d", channel]]
        if isPrivate { tags.append(["private"]) }
        return try event(.groupMetadata, json, tags: tags, at: seconds)
    }

    /// A kind-39002 relay-signed roster, naming everyone the relay counts a member.
    ///
    /// The sidebar wants this *and* a `channel_access` row, not either alone
    /// (`ChannelList.swift`): the roster is the relay's answer about who belongs, and the
    /// access mark is this device's answer about what to show. So a fixture that marks
    /// access without seeding a roster describes a channel nobody is in, and the list it
    /// is asserting against comes back empty — which is what happened to every test in
    /// `ChannelListModelTests` that carries a `selfPubkey`.
    ///
    /// Addressable by `d` like the metadata above, and authored by the same relay fixture,
    /// because the store projects `channel_member` from whoever signed it.
    func channelMembers(
        _ channel: String,
        _ members: [String],
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try event(
            .groupMembers,
            "",
            tags: [["d", channel]] + members.map { ["p", $0] },
            at: seconds
        )
    }
}
