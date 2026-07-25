import Foundation
import GRDB

/// One author's profile, as the `profile` projection (kind 0) holds it.
///
/// A query result, not a stored type: like ``ChannelListRow`` it is read fresh so a
/// `ValueObservation` over the `profile`/`event` region keeps a profile screen live
/// as newer metadata arrives (from this device's own edit, echoed, or another
/// device's).
public struct ProfileRow: Sendable, Hashable {
    public let pubkey: String
    public let displayName: String?
    public let about: String?
    public let picture: String?
    public let nip05: String?
    public let lud16: String?

    public init(
        pubkey: String,
        displayName: String? = nil,
        about: String? = nil,
        picture: String? = nil,
        nip05: String? = nil,
        lud16: String? = nil
    ) {
        self.pubkey = pubkey
        self.displayName = displayName
        self.about = about
        self.picture = picture
        self.nip05 = nip05
        self.lud16 = lud16
    }
}

public extension BuzzEventStore {
    /// The stored profile for `pubkey`, or `nil` when none has been seen.
    ///
    /// `nonisolated` over the concurrent reader so a view model can observe the
    /// `profile` projection off the actor — the same discipline as
    /// ``channelList(selfPubkey:)`` and ``timeline(channel:before:limit:)``.
    nonisolated func profile(pubkey: String) throws -> ProfileRow? {
        try reader.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT pubkey, display_name, about, picture, nip05, lud16 FROM profile WHERE pubkey = ?",
                arguments: [pubkey]
            )
            .map(Self.makeProfileRow)
        }
    }

    private static func makeProfileRow(_ row: Row) -> ProfileRow {
        ProfileRow(
            pubkey: row["pubkey"],
            displayName: row["display_name"],
            about: row["about"],
            picture: row["picture"],
            nip05: row["nip05"],
            lud16: row["lud16"]
        )
    }
}
