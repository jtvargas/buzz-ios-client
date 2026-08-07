import BuzzKit
import Foundation

/// The outcome of resolving an `@`-name to a mentioned user.
struct MentionMatch: Hashable, Sendable {
    let pubkey: String
    let isSelf: Bool
    /// Whether this pubkey is an agent. See ``MentionToken/isAgent`` for why this is
    /// the one field here that does not come from the message.
    let isAgent: Bool

    init(pubkey: String, isSelf: Bool, isAgent: Bool = false) {
        self.pubkey = pubkey
        self.isSelf = isSelf
        self.isAgent = isAgent
    }
}

/// Resolves the entity tokens the parser can only *see* as text into identity.
///
/// The seam that keeps rendering consistent everywhere: mention identity resolves
/// from the **message's own data** (its `p`-tag names), not an ambient roster, so a
/// message renders identically on every surface. Injected into the render path;
/// swapped for a stub in tests.
protocol MentionResolver {
    /// Resolves an `@`-name (as authored, one or more words) to a mentioned user, or
    /// `nil` when this message does not mention anyone by that name.
    func mention(forName name: String) -> MentionMatch?

    /// Resolves a `#`-name to a channel id, or `nil` when no known channel matches.
    func channel(forName name: String) -> String?

    /// The local identity's hex pubkey, for self-mention emphasis. `nil` when
    /// signed-out or key-unavailable (the keyless fallback other reads take).
    var selfPubkey: String? { get }

    /// A cheap, value-equal token that changes whenever resolution would change (a
    /// mentioned user's profile lands, the channel map updates, or the identity
    /// switches). The memo re-keys on it so a stale render is never reused.
    var identity: String { get }
}

/// The app-wide `#channel` name→id map, built once from the channel list and
/// injected down the view tree. Names are normalised (l-cased, whitespace-collapsed)
/// on both build and lookup; a name collision resolves to the first channel (the
/// Phase-4 first-match rule).
struct ChannelNameMap: Equatable, Sendable {
    private let byName: [String: String]
    let identity: String

    /// Builds the map from raw `(name, id)` pairs. Empty or whitespace-only names
    /// are skipped.
    init(_ entries: [(name: String, id: String)]) {
        var map: [String: String] = [:]
        for entry in entries {
            let key = RichTextName.normalized(entry.name)
            guard !key.isEmpty, map[key] == nil else { continue }
            map[key] = entry.id
        }
        byName = map
        identity = map.keys.sorted().map { "\($0)=\(map[$0]!)" }.joined(separator: ",")
    }

    /// Builds the map from channel-list rows, keying each channel's display name to
    /// its group id. A channel with no name is skipped — it has nothing to reference.
    init(channels: [ChannelListRow]) {
        self.init(channels.compactMap { row in
            guard let name = row.name, !name.isEmpty else { return nil }
            return (name: name, id: row.id)
        })
    }

    func id(forName name: String) -> String? {
        byName[RichTextName.normalized(name)]
    }

    static let empty = ChannelNameMap([])
}

/// The production resolver: mentions from a single message's `p`-tag refs, channels
/// from the injected app-wide map, self from the local identity.
///
/// A message's mention names are indexed by full name and by first name (matching
/// upstream), so both `@Ada Lovelace` and `@Ada` resolve; a full-name match is
/// preferred (the entity scan tries the longest span first). First-registered wins
/// on an alias collision, keeping resolution stable in authored `p`-tag order.
struct MessageMentionResolver: MentionResolver {
    private let mentionsByName: [String: MentionMatch]
    private let channels: ChannelNameMap
    let selfPubkey: String?
    let identity: String

    /// - Parameter agentPubkeys: every pubkey the app currently knows to be an agent.
    ///   Passed whole rather than pre-filtered so the caller does not have to know
    ///   which of its refs survive aliasing; only the ones this message actually
    ///   mentions reach ``identity``, so an unrelated agent joining a channel does not
    ///   invalidate every cached render in the app.
    init(
        mentions: [MentionRef],
        channels: ChannelNameMap,
        selfPubkey: String?,
        agentPubkeys: Set<String> = []
    ) {
        var byName: [String: MentionMatch] = [:]
        func match(_ ref: MentionRef) -> MentionMatch {
            MentionMatch(
                pubkey: ref.pubkey,
                isSelf: ref.pubkey == selfPubkey,
                isAgent: agentPubkeys.contains(ref.pubkey)
            )
        }

        // Full names first, so a multi-word name owns its key before any alias.
        for ref in mentions {
            let key = RichTextName.normalized(ref.displayName)
            guard !key.isEmpty, byName[key] == nil else { continue }
            byName[key] = match(ref)
        }
        // First-name aliases, never overwriting an established key.
        for ref in mentions {
            let full = RichTextName.normalized(ref.displayName)
            guard let first = full.split(separator: " ").first.map(String.init),
                  !first.isEmpty, first != full, byName[first] == nil else { continue }
            byName[first] = match(ref)
        }

        mentionsByName = byName
        self.channels = channels
        self.selfPubkey = selfPubkey

        // The agent flag is part of the key, not just of the value. It is the one term
        // here that can change while the message, the channel map and the identity all
        // stay put — a roster promotion or the agent directory landing — and a memo
        // keyed without it would keep serving the render made before the glyph existed.
        let mentionIdentity = mentions
            .map { ref in
                let agent = agentPubkeys.contains(ref.pubkey) ? "*" : ""
                return "\(ref.pubkey)\(agent):\(RichTextName.normalized(ref.displayName))"
            }
            .sorted()
            .joined(separator: ",")
        identity = "\(channels.identity)|\(mentionIdentity)|\(selfPubkey ?? "-")"
    }

    func mention(forName name: String) -> MentionMatch? {
        mentionsByName[RichTextName.normalized(name)]
    }

    func channel(forName name: String) -> String? {
        channels.id(forName: name)
    }
}
