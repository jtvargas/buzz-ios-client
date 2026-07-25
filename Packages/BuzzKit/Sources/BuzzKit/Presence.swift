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

/// One present member of the workspace: who they are, and the status they
/// announced. Presence is workspace-global (S-5), so a member is present in the
/// workspace rather than in any one channel.
public struct PresenceMember: Sendable, Equatable {
    public let pubkey: String
    public let status: PresenceStatus

    public init(pubkey: String, status: PresenceStatus) {
        self.pubkey = pubkey
        self.status = status
    }
}
