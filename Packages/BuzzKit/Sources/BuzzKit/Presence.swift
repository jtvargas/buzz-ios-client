/// A peer's announced availability in a channel.
///
/// The relay accepts an arbitrary status string on the presence (kind 20001)
/// WebSocket path for forward-compatibility, so this preserves an unrecognised
/// value in ``other(_:)`` rather than collapsing it — the same "never lose what the
/// wire said" stance ``NostrCore/EventKind`` takes for kinds. `"offline"` is
/// deliberately not a case: it is a *clear* signal the store acts on, never a
/// status a live peer holds.
public enum PresenceStatus: Sendable, Equatable {
    case online
    case away
    case other(String)

    /// Maps a raw status string to a case, preserving anything unrecognised.
    public init(_ raw: String) {
        switch raw {
        case "online": self = .online
        case "away": self = .away
        default: self = .other(raw)
        }
    }

    /// The wire string this status was, or would be, carried as.
    public var rawValue: String {
        switch self {
        case .online: "online"
        case .away: "away"
        case let .other(raw): raw
        }
    }
}

/// One present member of a channel: who they are, and the status they announced.
public struct PresenceMember: Sendable, Equatable {
    public let pubkey: String
    public let status: PresenceStatus

    public init(pubkey: String, status: PresenceStatus) {
        self.pubkey = pubkey
        self.status = status
    }
}

/// A channel's ephemeral presence at one moment: who is present (and how), and who
/// is typing.
///
/// This is what the UI layer subscribes to. Both lists are ordered by pubkey so
/// two equal states compare equal — the change-vs-no-op test the store's observer
/// stream turns on — and so a view renders members in a stable order rather than
/// the arbitrary order of a dictionary walk.
public struct ChannelPresence: Sendable, Equatable {
    public let channel: String
    public let present: [PresenceMember]
    public let typing: [String]

    public init(channel: String, present: [PresenceMember], typing: [String]) {
        self.channel = channel
        self.present = present
        self.typing = typing
    }

    /// Whether the channel currently has no live presence and no one typing.
    public var isEmpty: Bool {
        present.isEmpty && typing.isEmpty
    }

    /// The no-presence snapshot for a channel — the baseline a first observer is
    /// seeded with, and what a channel decays back to once everything lapses.
    static func empty(_ channel: String) -> ChannelPresence {
        ChannelPresence(channel: channel, present: [], typing: [])
    }
}
