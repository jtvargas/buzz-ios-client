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

    /// Every identity the directory holds — the rosters of every channel this account is in,
    /// plus the agent directory, plus the reader themselves. Unordered.
    ///
    /// The only enumeration this type offers, and it exists for one caller: the
    /// new-direct-message sheet has to *offer* people before anybody has named one, which
    /// every other accessor here assumes has already happened. Unordered because the sort
    /// belongs to the surface — ``DirectMessagePicker`` puts people before agents and named
    /// before merely identified, which is a rule about that list rather than about identity.
    var identities: [String] {
        Array(snapshot.entities.keys)
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

    /// How `channel` presents itself: a channel, a direct message with a person, with an
    /// agent, or with several people — with the title, artwork, and peer that go with it.
    func conversation(for channel: String) -> ConversationIdentity {
        conversation(for: channelsByID[channel], id: channel)
    }

    /// The same resolution from a channel-list row already in hand, so the sidebar
    /// does not need the row's id looked back up.
    func conversation(for row: ChannelListRow) -> ConversationIdentity {
        conversation(for: row, id: row.id)
    }

    /// The same resolution, told who the conversation is with by a caller that already
    /// knows — used only where the roster cannot answer yet.
    ///
    /// The relay's DM open command replies with the channel id and commits the channel's
    /// membership *afterwards*, so a roster read taken the moment the reply lands can
    /// legitimately be empty (`SyncEngineDirectMessageTests` documents that read-back).
    /// ``directPeer(in:)`` then finds no two-member roster, the conversation classifies as
    /// a channel, and — having no metadata name either — titles itself
    /// ``untitledChannel``: a placeholder standing where the name of the people the tap
    /// explicitly named should be.
    ///
    /// The hint is consulted *after* the roster and only when the roster is silent, so it
    /// can never override the product rule — it fills the gap before the rule has anything
    /// to say. It also stays a caller's fact rather than a second derivation: the only
    /// thing allowed to produce a peer is ``directPeer(in:)`` or an answer from the relay.
    ///
    /// Several hinted people are a group, and it is titled by ``title(joining:)`` — the same
    /// function ``groupTitle(for:id:)`` uses once the roster lands. So the title before and
    /// after are the same string, and nothing flashes as the membership arrives.
    func conversation(for row: ChannelListRow, knownPeers: [String]) -> ConversationIdentity {
        conversation(for: row, id: row.id, knownPeers: knownPeers)
    }

    private func conversation(
        for row: ChannelListRow?,
        id: String,
        knownPeers: [String] = []
    ) -> ConversationIdentity {
        // The directory's own row wins; a caller's is a *stand-in* for a channel the
        // directory has not got yet.
        //
        // ``ChannelListView/conversationRow(for:)`` fabricates one — no name, and no
        // `t=dm` — for a channel the relay has just answered with but that has not reached
        // the live list, and ``ConversationRoute`` then holds that value for the whole life
        // of the push. Without this line the conversation asks forever about a row that
        // never learns it is a direct message, while taking its *title* from the live one:
        // the classification came from the stand-in and the string from the directory, and
        // a group opened from the picker read `Group DM (4)`.
        let row = channelsByID[id] ?? row
        let members = snapshot.members(of: id)
        let hint = knownPeers.count == 1 ? knownPeers.first : nil
        if let peer = directPeer(in: id) ?? unprojectedPeer(in: id, hint: hint) {
            return ConversationIdentity(
                channelID: id,
                kind: isAgent(peer) ? .agent : .direct,
                title: name(for: peer),
                peer: peer,
                picture: picture(for: peer),
                initials: initials(for: peer),
                isPrivate: row?.isPrivate ?? true,
                memberCount: members.count
            )
        }
        // A direct message with more than one other person in it. The *relay* decides
        // this, not the roster: a group DM and a private channel are the same shape from
        // here — several people, no name they chose — and only one of them should be
        // filed and titled by who is in it.
        if row?.isDirectMessage == true, members.count > 2 {
            return ConversationIdentity(
                channelID: id,
                kind: .group,
                title: groupTitle(for: row, id: id),
                peer: nil,
                picture: nil,
                initials: Self.initials(from: row?.name),
                isPrivate: row?.isPrivate ?? true,
                memberCount: members.count
            )
        }
        // The same gap ``unprojectedPeer(in:hint:)`` fills, for a group: a conversation the
        // relay opened seconds ago whose membership has not been projected yet. Titled by the
        // people the tap named, which is the string the roster will produce — so this is the
        // conversation appearing already named rather than a placeholder being replaced.
        if let hinted = unprojectedGroup(in: id, hints: knownPeers) {
            return ConversationIdentity(
                channelID: id,
                kind: .group,
                title: title(joining: hinted),
                peer: nil,
                picture: nil,
                initials: Self.initials(from: row?.name),
                isPrivate: row?.isPrivate ?? true,
                // The people named, plus you — which is what the roster will hold once it
                // lands. A count that grew by one at that moment would be the mark changing
                // under a reader already looking at it.
                memberCount: hinted.count + 1
            )
        }
        return ConversationIdentity(
            channelID: id,
            kind: .channel,
            title: channelName(for: id),
            peer: nil,
            picture: row?.picture.flatMap(URL.init(string:)),
            initials: Self.initials(from: row?.name),
            isPrivate: row?.isPrivate ?? false,
            memberCount: members.count
        )
    }

    /// What to call a group direct message: the people in it, by name — the Slack
    /// convention, and the one the Buzz desktop and Flutter clients already follow.
    ///
    /// A name somebody *chose* wins. Everything else is the relay's own placeholder —
    /// `DM`, `Group DM (4)` — which names nobody and, unlike a channel's name, is not a
    /// thing anyone typed; rendering it is the same category of mistake as rendering a
    /// group id. Falls back to the placeholder only when there is nobody left to list,
    /// which is a roster that has not arrived rather than a group of one.
    ///
    /// Ordered by the rendered name and then by key, because a roster is a `Set`: without
    /// a total order the same conversation would list its people differently on each pass.
    private func groupTitle(for row: ChannelListRow?, id: String) -> String {
        let given = row?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let given, !Self.isGenericDirectMessageName(given) { return given }
        let others = snapshot.members(of: id).filter { $0 != selfPubkey }
        guard !others.isEmpty else { return channelName(for: id) }
        return title(joining: others)
    }

    /// A set of people as one title: their names, in order, comma-separated.
    ///
    /// Lifted out of ``groupTitle(for:id:)`` so there is exactly one spelling of "how a group
    /// is named" — the roster's answer once it lands, and the hint's answer before it does
    /// (see ``unprojectedGroup(in:hints:)``). Two spellings would mean the title changing at
    /// the moment the membership arrived, which is the flash this hint exists to prevent.
    ///
    /// Ordered by the rendered name and then by key, because a roster is a `Set`: without a
    /// total order the same conversation would list its people differently on each pass.
    private func title(joining peers: some Collection<String>) -> String {
        peers
            .map { (pubkey: $0, label: name(for: $0)) }
            .sorted { lhs, rhs in
                let comparison = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.pubkey < rhs.pubkey
            }
            .map(\.label)
            .joined(separator: ", ")
    }

    /// Whether a direct message's name is the relay's placeholder rather than one a
    /// person chose: `DM`, `Direct message`, `Group DM`, `Group DM (4)`.
    ///
    /// The exact set the desktop and Flutter clients test for
    /// (`channelLabels.ts`, `dm_channel_labels.dart`), so the three agree about which
    /// group DMs are titled by their people. The relay writes `DM` for two and
    /// `Group DM (N)` for three or more (`RESEARCH/BUZZ_DM_OPEN_PROTOCOL.md`).
    static func isGenericDirectMessageName(_ name: String?) -> Bool {
        let normalized = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.isEmpty
            || normalized == "dm"
            || normalized == "direct message"
            || normalized == "direct messages" {
            return true
        }
        guard normalized.hasPrefix("group dm") else { return false }
        let suffix = normalized
            .dropFirst("group dm".count)
            .trimmingCharacters(in: .whitespaces)
        if suffix.isEmpty { return true }
        guard suffix.hasPrefix("("), suffix.hasSuffix(")") else { return false }
        let digits = suffix.dropFirst().dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// A caller's peer hint, but only while the roster cannot answer for itself.
    ///
    /// "Cannot answer" is a roster of fewer than two people: a conversation with somebody
    /// has at least two members in it, so anything smaller is a membership read that has not
    /// finished rather than a fact about the channel. Two or more *is* an answer, and then
    /// ``directPeer(in:)`` has already given it — a hint is not allowed to contradict the
    /// product rule, only to stand in before the rule has anything to apply.
    ///
    /// A keyless session refuses the hint too, for the same reason it reads every
    /// conversation as a channel: with no local identity there is no "other" member.
    private func unprojectedPeer(in channel: String, hint: String?) -> String? {
        guard let hint, selfPubkey != nil, snapshot.members(of: channel).count < 2 else {
            return nil
        }
        return hint.lowercased()
    }

    /// The same hint, for a group: the people a caller named, while the roster still cannot
    /// answer for itself. `nil` once it can, or when fewer than two people are left — one is
    /// a one-to-one and ``unprojectedPeer(in:hint:)`` has already answered it.
    ///
    /// De-duplicated and with the local identity dropped, in the order the caller named them
    /// — which is the same shaping the relay applies to the `p` tags, so the count here and
    /// the count the roster lands with agree.
    private func unprojectedGroup(in channel: String, hints: [String]) -> [String]? {
        guard let selfPubkey, snapshot.members(of: channel).count < 2 else { return nil }
        var seen: Set<String> = [selfPubkey]
        var others: [String] = []
        for hint in hints.map({ $0.lowercased() }) where seen.insert(hint).inserted {
            others.append(hint)
        }
        return others.count > 1 ? others : nil
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

    /// The name to render for a channel — its metadata name, or a human placeholder
    /// when the relay has not given it one.
    ///
    /// Never any part of the group id. Eight characters of one is still a group id, and
    /// this answer is the sidebar title, the conversation's nav title, the details title,
    /// and a thread's subtitle — so `#a3f9b21c` was that identifier reaching the screen in
    /// four places, most visibly for a DM group another client created with no metadata
    /// name. The deliberate display of a group id lives in the details sheet's Developer
    /// section, labelled for what it is.
    /// A direct message's relay-given name never survives this. `DM`, `Group DM (4)` — the
    /// relay writes those, nobody chose them, and they name none of the people in the room.
    /// ``groupTitle(for:id:)`` has always rejected them; this is the same rejection on the
    /// other door into the same string, for the conversations that reach here instead: a DM
    /// whose roster has not arrived, so there is nobody to list yet. `Untitled conversation`
    /// says that honestly. The gate is ``BuzzKit/ChannelListRow/isDirectMessage`` and not
    /// the shape of the name, because a channel somebody deliberately called `Group DM (4)`
    /// chose that name and nothing here is entitled to overrule it.
    func channelName(for channel: String) -> String {
        let row = channelsByID[channel]
        let name = row?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if row?.isDirectMessage == true, Self.isGenericDirectMessageName(name) {
            return Self.untitledChannel
        }
        if let name, !name.isEmpty { return name }
        return Self.untitledChannel
    }

    /// What an unnamed conversation is called. A phrase rather than an identifier: the
    /// reader cannot act on a group id, and a name they can read is the only honest thing
    /// to put where a name goes.
    static let untitledChannel = "Untitled conversation"

    /// `channel`'s roster, for a member list or a DM's peer.
    func members(of channel: String) -> Set<String> {
        snapshot.members(of: channel)
    }

    // MARK: - Mentions

    /// `refs` with each pubkey's *directory* name registered as a second alias.
    ///
    /// ``BuzzEventStore/mentions(for:)`` resolves a `MentionRef`'s name from the `profile`
    /// projection alone and falls back to `pubkey.prefix(8)`. Every surface that renders a
    /// message resolves its `@`-tokens against those refs, so for a mentioned user with no
    /// kind-0 profile the token either rendered as a tinted eight-character key — a §4
    /// leak — or, when it was authored against an agent-directory or NIP-05 name, matched
    /// nothing and fell out as plain text. This is the fix, and it belongs here rather
    /// than on one surface: registering the directory's answer alongside the store's gives
    /// the scan both spellings everywhere at once.
    ///
    /// Originals come first, so the store's authored `p`-tag order still wins any name
    /// collision (``MessageMentionResolver`` keeps the first registration of a key).
    func aliased(_ refs: [MentionRef]) -> [MentionRef] {
        var seen: Set<String> = []
        var merged: [MentionRef] = []
        for ref in refs where seen.insert("\(ref.pubkey)|\(ref.displayName)").inserted {
            merged.append(ref)
        }
        for ref in refs {
            let resolved = name(for: ref.pubkey)
            guard seen.insert("\(ref.pubkey)|\(resolved)").inserted else { continue }
            merged.append(MentionRef(pubkey: ref.pubkey, displayName: resolved))
        }
        return merged
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
