import Foundation

/// A Nostr event kind.
///
/// Backed by an `Int` rather than a closed enum so that kinds this client does
/// not recognise still survive a decode/encode round trip untouched. The wider
/// Nostr ecosystem adds kinds faster than any one client tracks them; a closed
/// enum would force every unknown kind to be dropped or to fail decoding, which
/// would corrupt an event log meant to be an append-only mirror of the wire.
public struct EventKind: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(integerLiteral value: Int) {
        rawValue = value
    }

    // MARK: - NIP-01 / NIP-02 core

    public static let metadata: EventKind = 0
    public static let textNote: EventKind = 1
    public static let contactList: EventKind = 3
    public static let deletion: EventKind = 5
    public static let reaction: EventKind = 7

    // MARK: - NIP-29 relay-based group messaging

    public static let channelMessage: EventKind = 9

    // MARK: - Encrypted transport, reporting, zaps

    public static let giftWrap: EventKind = 1059
    public static let report: EventKind = 1984
    public static let zapRequest: EventKind = 9734
    public static let zapReceipt: EventKind = 9735

    // MARK: - Authentication

    public static let clientAuthentication: EventKind = 22242
    public static let blossomAuthorization: EventKind = 24242
    public static let httpAuthentication: EventKind = 27235

    // MARK: - NIP-29 group moderation commands

    public static let groupAddUser: EventKind = 9000
    public static let groupRemoveUser: EventKind = 9001
    public static let groupEditMetadata: EventKind = 9002
    public static let groupDeleteEvent: EventKind = 9005
    public static let groupCreate: EventKind = 9007
    public static let groupDelete: EventKind = 9008
    public static let groupCreateInvite: EventKind = 9009
    public static let groupJoinRequest: EventKind = 9021
    public static let groupLeaveRequest: EventKind = 9022

    // MARK: - Relay membership administration (NIP-43 / NIP-WP)

    public static let relayAddMember: EventKind = 9030
    public static let relayRemoveMember: EventKind = 9031
    public static let relayChangeRole: EventKind = 9032
    public static let relaySetWorkspaceProfile: EventKind = 9033

    // MARK: - Archival requests (NIP-IA)

    public static let archiveRequest: EventKind = 9035
    public static let unarchiveRequest: EventKind = 9036

    // MARK: - Presence (ephemeral)

    public static let presence: EventKind = 20001
    public static let typing: EventKind = 20002

    // MARK: - Device pairing (NIP-AB, ephemeral)

    /// The single event kind NIP-AB device pairing uses for every message —
    /// `offer`, `sas-confirm`, `payload`, `complete`, `abort` — each NIP-44 v2
    /// encrypted and addressed to a throwaway ephemeral pubkey. In the ephemeral
    /// range, so relays route but never store it.
    public static let devicePairing: EventKind = 24134

    // MARK: - Rich channel messaging

    public static let richMessage: EventKind = 40002
    public static let messageEdit: EventKind = 40003

    // MARK: - Addressable application state

    public static let readState: EventKind = 30078
    public static let agentEngram: EventKind = 30174
    public static let persona: EventKind = 30175
    public static let reminder: EventKind = 30300

    // MARK: - Relay-signed group state (addressable)

    public static let groupMetadata: EventKind = 39000
    public static let groupAdmins: EventKind = 39001
    public static let groupMembers: EventKind = 39002
    public static let groupRoles: EventKind = 39003

    // MARK: - Relay-signed channel-window overlays (addressable)

    public static let threadSummary: EventKind = 39005
    public static let windowBounds: EventKind = 39006

    // MARK: - Relay-signed membership state and notifications

    public static let membershipList: EventKind = 13534
    public static let memberAdded: EventKind = 44100
    public static let memberRemoved: EventKind = 44101

    // MARK: - NIP-01 storage classes

    /// Ephemeral events (20000..<30000) are never persisted by relays.
    public var isEphemeral: Bool {
        (20000 ..< 30000).contains(rawValue)
    }

    /// Replaceable events keep only the newest per author: the parameterless
    /// range 10000..<20000, plus the special-cased profile (0) and contact list
    /// (3) from NIP-01/NIP-02.
    public var isReplaceable: Bool {
        rawValue == 0 || rawValue == 3 || (10000 ..< 20000).contains(rawValue)
    }

    /// Addressable events (30000..<40000) keep the newest per
    /// (author, kind, `d` tag).
    public var isAddressable: Bool {
        (30000 ..< 40000).contains(rawValue)
    }

    // MARK: - Publish guard

    /// Kinds the relay produces and signs itself. A client must never attempt to
    /// publish these; the relay is their sole author.
    public var isRelaySigned: Bool {
        Self.relaySignedKinds.contains(self)
    }

    private static let relaySignedKinds: Set<EventKind> = [
        .groupMetadata, .groupAdmins, .groupMembers, .groupRoles,
        .threadSummary, .windowBounds,
        .membershipList, .memberAdded, .memberRemoved,
    ]
}

// MARK: - Codable

extension EventKind: Codable {
    /// Coded as a bare integer so an event's `kind` field stays wire-shaped
    /// (`"kind": 1`) rather than wrapped in a keyed container.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - CustomStringConvertible

extension EventKind: CustomStringConvertible {
    public var description: String {
        String(rawValue)
    }
}
