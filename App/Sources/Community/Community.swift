import Foundation

/// One community this device is signed in to: a relay, the identity used there, and the two
/// places on this phone that hold that community's data.
///
/// # Why the record names its own storage instead of deriving it
///
/// Both the Keychain account and the database filename are *stored on the record* rather
/// than computed from ``id``. That is what makes the first migration free: the install that
/// exists today keeps its key under `primary` and its history in `store.sqlite`, and becomes
/// community #1 by having those two strings written into its record — no key is moved and no
/// database is renamed. A naming convention would have required moving both, and a
/// half-completed Keychain move is an identity this device can no longer sign with.
///
/// # What is deliberately not here
///
/// The secret key. It lives in the Keychain under ``keychainAccount`` and nowhere else; this
/// record is written to `UserDefaults` in the clear. Desktop learned that the other way
/// round — it used to keep the `nsec` in `localStorage` and now strips it on every read
/// (`buzz/desktop/src/features/communities/communityStorage.ts:57-79`), and the Flutter
/// client keeps its copy in `flutter_secure_storage` precisely because it does hold one
/// (`buzz/mobile/lib/shared/community/community_storage.dart`). Hive holds none, so its
/// directory has nothing worth protecting beyond what a relay URL already reveals.
struct Community: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// The label over the home screen.
    ///
    /// Derived from the relay's host when the community is added (§ ``CommunityIdentity``)
    /// and renameable afterwards, because in Buzz the community name is a client-local
    /// label everywhere: no relay will answer for it, deliberately — see the long note on
    /// ``CommunityIdentity`` for why NIP-11 cannot be asked.
    var name: String
    /// The websocket URL the engine connects on for this community.
    var relayURLString: String
    /// The Keychain account this community's secret key is stored under, within the app's
    /// one Keychain service.
    ///
    /// `KeychainSigner` was built for this — "an app holding several identities uses one
    /// signer per account" (`KeychainSigner.swift:89-90`) — so a community is signed for by
    /// its own signer and no two communities can sign with each other's key by accident.
    /// Two communities paired from the same desktop hold the same key material under two
    /// accounts, which costs a few hundred bytes and buys the ability to remove one without
    /// touching the other.
    let keychainAccount: String
    /// The database file inside `Application Support/Hive` holding this community's events.
    ///
    /// One file per community rather than one file with a community column: the store is a
    /// verified event log with projections built off it, and a column would put the
    /// isolation in every query in ``BuzzKit`` — where a single missed `WHERE` shows another
    /// community's messages. A separate file cannot leak by omission.
    let storeFilename: String
    /// Whose data ``storeFilename`` currently holds, or `nil` before anything has been
    /// stored for this community.
    ///
    /// This is the per-community form of what used to be one global `UserDefaults` key. It
    /// has to be per community now: with several stores on disk, "a different key signed in"
    /// is a question about *one* store file, and answering it globally would wipe the
    /// histories of communities the new key never touched.
    var ownerPubkeyHex: String?
    let addedAt: Date

    /// The Keychain account and database file the single-community app used. A migrated
    /// install keeps both; nothing new is ever given them.
    static let legacyKeychainAccount = "primary"
    static let legacyStoreFilename = "store.sqlite"

    /// A brand-new community, with storage of its own that no other community can name.
    static func new(
        relayURLString: String,
        name: String? = nil,
        ownerPubkeyHex: String? = nil,
        id: UUID = UUID(),
        addedAt: Date = Date()
    ) -> Community {
        Community(
            id: id,
            name: name ?? CommunityIdentity.name(forRelay: relayURLString),
            relayURLString: relayURLString,
            keychainAccount: "community-\(id.uuidString)",
            storeFilename: "store-\(id.uuidString).sqlite",
            ownerPubkeyHex: ownerPubkeyHex,
            addedAt: addedAt
        )
    }

    /// The install that existed before this app had a community list, adopted as community
    /// #1 in place: its key stays where the signer already looks, and its history stays in
    /// the file the store already has open.
    static func adoptingLegacyInstall(
        relayURLString: String,
        ownerPubkeyHex: String?,
        id: UUID = UUID(),
        addedAt: Date = Date()
    ) -> Community {
        Community(
            id: id,
            name: CommunityIdentity.name(forRelay: relayURLString),
            relayURLString: relayURLString,
            keychainAccount: legacyKeychainAccount,
            storeFilename: legacyStoreFilename,
            ownerPubkeyHex: ownerPubkeyHex,
            addedAt: addedAt
        )
    }

    /// The relay this record is compared on, so one relay cannot become two communities.
    ///
    /// Both other clients dedupe on the relay URL and update the existing entry's
    /// credentials rather than appending a second one — Flutter at
    /// `community_provider.dart:24-42`, Desktop at `useCommunities.tsx` (`addCommunity`).
    /// Hive compares a canonical form rather than the raw string, because a host is
    /// case-insensitive and a trailing slash is not a different relay: someone who typed
    /// `wss://Homelab.ts.net/` today and `wss://homelab.ts.net` tomorrow would otherwise get
    /// two entries listing the same conversations, each with its own copy of the same
    /// history. Returns `nil` for a string that is not a relay URL at all, which callers
    /// treat as "no match" rather than as a match against other unparseable strings.
    ///
    /// A port that is the *default* for the scheme is dropped, for the same reason a
    /// trailing slash is: `wss://relay.example:443` and `wss://relay.example` are one
    /// destination written two ways. Flutter does the same
    /// (`invite_join_provider.dart:227-234`), and the relay itself strips `:443`/`:80`
    /// before deciding which community a request belongs to
    /// (`buzz-core/src/tenant.rs:124-132`). It matters more now that a relay URL can arrive
    /// from an invite link rather than only from the field somebody typed.
    static func relayIdentity(of urlString: String) -> String? {
        guard let url = RelayEndpoint.websocketURL(from: urlString),
              let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased()
        else { return nil }
        let defaultPort = scheme == "wss" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        var path = url.path()
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// Whether this record and `urlString` name the same relay.
    func isSameRelay(as urlString: String) -> Bool {
        guard let mine = Community.relayIdentity(of: relayURLString),
              let theirs = Community.relayIdentity(of: urlString)
        else { return false }
        return mine == theirs
    }
}
