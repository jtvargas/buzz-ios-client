import Foundation

/// Where the community list lives between launches: JSON in `UserDefaults`, beside the
/// relay URL that used to be the whole of this app's idea of a workspace.
///
/// `UserDefaults` and not the Keychain, because nothing here is a secret — a record is a
/// relay URL, a label, and the *names* of the two places this community's data sits. The
/// key itself never appears in it (§ ``Community``).
struct CommunityStorage {
    private let defaults: UserDefaults

    /// - Parameter defaults: injected so a test can drive a throwaway suite instead of the
    ///   app's own defaults, which a test run shares with whatever is installed.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static let listKey = "communities.v1"
    private static let activeKey = "communities.activeID"

    /// The stored directory, or an empty one on a fresh install *and* on anything that
    /// cannot be decoded.
    ///
    /// A decode failure is treated as "no communities" rather than as a launch error on
    /// purpose: the recovery from an empty directory is onboarding, which is a screen a
    /// reader can act on, and the histories on disk are not lost by it — a re-added relay
    /// finds its own store file again by name only if the record survived, so this is a
    /// real cost, but a launch that refuses to start is a worse one. The version in the key
    /// is what keeps this from being the ordinary path: a future shape change gets a new
    /// key rather than failing to read the old one.
    func load() -> CommunityDirectory {
        guard let data = defaults.data(forKey: Self.listKey),
              let communities = try? JSONDecoder().decode([Community].self, from: data)
        else { return CommunityDirectory() }
        let activeID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        return CommunityDirectory(communities: communities, activeID: activeID)
    }

    func save(_ directory: CommunityDirectory) {
        if let data = try? JSONEncoder().encode(directory.communities) {
            defaults.set(data, forKey: Self.listKey)
        }
        if let activeID = directory.activeID {
            defaults.set(activeID.uuidString, forKey: Self.activeKey)
        } else {
            defaults.removeObject(forKey: Self.activeKey)
        }
    }

    /// Forgets every community. Used by a sign-out, which leaves them all at once.
    func clear() {
        defaults.removeObject(forKey: Self.listKey)
        defaults.removeObject(forKey: Self.activeKey)
    }

    /// The directory to launch with, adopting the single-community install if that is what
    /// this device is.
    ///
    /// The adoption is the whole of the migration, and it moves nothing: the phone that
    /// upgrades into this build keeps signing with the key under `primary` and keeps
    /// reading `store.sqlite`, because those two strings are written into community #1's
    /// record rather than being conventions it has to match (§ ``Community``). The reader
    /// sees the same workspace under the same name, now with a switcher over it.
    ///
    /// - Parameter hasLegacyIdentity: whether a key is stored under
    ///   ``Community/legacyKeychainAccount``. Passed in rather than read here so this stays
    ///   a function of its inputs, and so the Keychain is touched in one place — the
    ///   composition root, which owns the signer.
    func loadAdoptingLegacyInstall(hasLegacyIdentity: Bool) -> CommunityDirectory {
        var directory = load()
        guard directory.isEmpty, hasLegacyIdentity else { return directory }
        directory.add(
            .adoptingLegacyInstall(
                relayURLString: RelayEndpoint.storedURLString,
                ownerPubkeyHex: StoreOwnership.legacyOwnerPubkeyHex
            )
        )
        save(directory)
        return directory
    }
}
