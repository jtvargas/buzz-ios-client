import BuzzKit
import Foundation
import NostrCore

/// The app's one answer to "what do I call this?".
///
/// Every surface — a message row, a mention suggestion, a member list, a DM title,
/// a sidebar row, a typing strip — resolves names, avatars, and conversation
/// identity through this value. It is built once per directory change from a
/// ``DirectorySnapshot`` plus the live channel list, and injected down the view
/// tree, so a row never issues a query, scans a roster, or invents its own
/// fallback. That is what keeps a raw pubkey or channel id from leaking into the
/// UI in exactly the places nobody remembered to handle.
///
/// # Fallback order
///
/// 1. the kind-0 profile display name;
/// 2. the agent directory's configured name (kind 10100);
/// 3. the NIP-05 username (its local part, or the domain for the `_` root form);
/// 4. only then a shortened `npub1abcdefg…wxyz` identifier.
///
/// A full 64-character hex key or a channel's group id is never rendered.
struct EntityNames: Equatable, Sendable {
    /// Identities and rosters, as the store handed them over.
    private let snapshot: DirectorySnapshot
    /// Channel metadata by group id, for titles and conversation identity.
    private let channelsByID: [String: ChannelListRow]
    /// Pre-computed short identifiers, for the *nameless* identities only — the ones
    /// a row would otherwise bech32-encode on every render pass. Naming the rest
    /// keeps building this value proportional to the problem instead of the roster.
    private let shortIdentifiers: [String: String]
    /// The local identity, which decides whose side of a two-member roster is the
    /// "peer". `nil` (keyless fallback) makes every conversation read as a channel.
    let selfPubkey: String?

    static let empty = EntityNames()

    init(
        snapshot: DirectorySnapshot = .empty,
        channels: [ChannelListRow] = [],
        selfPubkey: String? = nil
    ) {
        self.snapshot = snapshot
        channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        shortIdentifiers = snapshot.entities.reduce(into: [:]) { result, element in
            guard Self.humanName(of: element.value) == nil else { return }
            result[element.key] = Self.shortIdentifier(element.key)
        }
        self.selfPubkey = selfPubkey?.lowercased()
    }

    // MARK: - Identities

    func entity(for pubkey: String) -> DirectoryEntity? {
        snapshot.entity(pubkey)
    }

    /// The name to render for `pubkey` — never empty, never a full key.
    func name(for pubkey: String) -> String {
        humanName(for: pubkey) ?? shortIdentifier(for: pubkey)
    }

    /// The human-chosen name for `pubkey`, or `nil` when only an identifier exists.
    /// Callers that must distinguish "named" from "merely identified" (a member list
    /// sorting unnamed people last, say) use this rather than ``name(for:)``.
    func humanName(for pubkey: String) -> String? {
        entity(for: pubkey).flatMap(Self.humanName(of:))
    }

    /// The fallback chain itself, over one identity's raw fields.
    private static func humanName(of entity: DirectoryEntity) -> String? {
        if let profileName = entity.profileName { return profileName }
        if let agentName = entity.agentName { return agentName }
        if let nip05 = entity.nip05 { return username(fromNIP05: nip05) }
        return nil
    }

    /// The avatar artwork for `pubkey`, or `nil` to fall back to a monogram.
    func picture(for pubkey: String) -> URL? {
        entity(for: pubkey)?.picture.flatMap(URL.init(string:))
    }

    /// Up to two initials for the fallback avatar: `Ada Lovelace` → `AL`. Falls back
    /// to a single glyph when only an identifier is known, since the letters of an
    /// npub carry no meaning.
    func initials(for pubkey: String) -> String {
        Self.initials(from: humanName(for: pubkey))
    }

    func isAgent(_ pubkey: String) -> Bool {
        entity(for: pubkey)?.isAgent ?? false
    }

    /// The quiet second line beside a name: the NIP-05 identifier when there is one,
    /// otherwise "Agent" for an agent and nothing for a person.
    func secondaryLabel(for pubkey: String) -> String? {
        guard let entity = entity(for: pubkey) else { return nil }
        if let nip05 = entity.nip05 { return nip05 }
        return entity.isAgent ? "Agent" : nil
    }

    /// The shortened `npub1abcdefg…wxyz` form — the only identifier the UI shows,
    /// and only when no human-readable name exists anywhere.
    func shortIdentifier(for pubkey: String) -> String {
        shortIdentifiers[pubkey.lowercased()] ?? Self.shortIdentifier(pubkey)
    }

    // MARK: - Conversations

    /// How `channel` presents itself: a channel, a direct message with a person, or
    /// a direct message with an agent — with the title, artwork, and peer that go
    /// with it.
    func conversation(for channel: String) -> ConversationIdentity {
        conversation(for: channelsByID[channel], id: channel)
    }

    /// The same resolution from a channel-list row already in hand, so the sidebar
    /// does not need the row's id looked back up.
    func conversation(for row: ChannelListRow) -> ConversationIdentity {
        conversation(for: row, id: row.id)
    }

    private func conversation(for row: ChannelListRow?, id: String) -> ConversationIdentity {
        if let peer = directPeer(in: id) {
            return ConversationIdentity(
                channelID: id,
                kind: isAgent(peer) ? .agent : .direct,
                title: name(for: peer),
                peer: peer,
                picture: picture(for: peer),
                initials: initials(for: peer),
                isPrivate: row?.isPrivate ?? true
            )
        }
        return ConversationIdentity(
            channelID: id,
            kind: .channel,
            title: channelName(for: id),
            peer: nil,
            picture: row?.picture.flatMap(URL.init(string:)),
            initials: Self.initials(from: row?.name),
            isPrivate: row?.isPrivate ?? false
        )
    }

    /// The other member of a two-person roster that includes the local identity —
    /// the product rule for "this is a DM": a direct message *is* a channel whose
    /// roster is exactly the two people in it. Any other roster size, an unknown
    /// roster, or a keyless session reads as a channel.
    func directPeer(in channel: String) -> String? {
        guard let selfPubkey else { return nil }
        let members = snapshot.members(of: channel)
        guard members.count == 2, members.contains(selfPubkey) else { return nil }
        return members.first { $0 != selfPubkey }
    }

    /// The name to render for a channel — its metadata name, or a short form of its
    /// group id when the relay has not given it one.
    func channelName(for channel: String) -> String {
        if let name = channelsByID[channel]?.name, !name.isEmpty { return name }
        return String(channel.prefix(8))
    }

    /// `channel`'s roster, for a member list or a DM's peer.
    func members(of channel: String) -> Set<String> {
        snapshot.members(of: channel)
    }

    // MARK: - Pure helpers

    /// The username half of a NIP-05 identifier: `ada@buzz.dev` → `ada`. The `_`
    /// root form has no username, so its domain is the name (the NIP-05 convention).
    static func username(fromNIP05 nip05: String) -> String? {
        let parts = nip05.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            let single = nip05.trimmingCharacters(in: .whitespacesAndNewlines)
            return single.isEmpty ? nil : single
        }
        let local = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if local.isEmpty || local == "_" {
            return domain.isEmpty ? nil : domain
        }
        return local
    }

    /// Up to two initials from a display name, or `?` when there is no name to take
    /// them from.
    static func initials(from name: String?) -> String {
        guard let name else { return "?" }
        let words = name
            .split { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." }
            .compactMap { $0.first(where: \.isLetter) ?? $0.first(where: \.isNumber) }
        guard let first = words.first else { return "?" }
        if let second = words.dropFirst().first {
            return "\(first)\(second)".uppercased()
        }
        return String(first).uppercased()
    }

    /// `npub1abcdefg…wxyz` — enough of the bech32 form to recognise, short enough to
    /// sit in a row. Hex that is not a 32-byte key degrades to its first characters
    /// rather than rendering whole.
    static func shortIdentifier(_ pubkey: String) -> String {
        guard let raw = Hex.decode(pubkey.lowercased()), raw.count == 32 else {
            return String(pubkey.prefix(8))
        }
        let npub = NIP19.encodePublicKey(raw)
        return "\(npub.prefix(9))…\(npub.suffix(4))"
    }
}

/// How one conversation presents itself: a channel, a DM with a person, or a DM with
/// an agent — resolved once by ``EntityNames`` and reused by the sidebar, the
/// conversation header, and the thread header, so all three agree.
struct ConversationIdentity: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case channel
        case direct
        case agent
    }

    /// The underlying channel's group id. Never rendered — carried so a view can act
    /// on the conversation it names.
    let channelID: String
    let kind: Kind
    /// The name to show: the channel's name, or the peer's for a direct message.
    let title: String
    /// The other person in a direct message; `nil` for a channel.
    let peer: String?
    let picture: URL?
    let initials: String
    let isPrivate: Bool

    var id: String { channelID }

    /// Whether this is a one-to-one conversation (with a person or an agent).
    var isDirect: Bool { kind != .channel }

    /// The seed for a monogram's colour — the peer for a DM so a person keeps one
    /// tint everywhere, the channel otherwise.
    var avatarSeed: String { peer ?? channelID }
}
