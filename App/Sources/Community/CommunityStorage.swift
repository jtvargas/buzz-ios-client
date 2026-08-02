import Foundation

/// Where the community list lives between launches: JSON in `UserDefaults`, beside the
/// relay URL that used to be the whole of this app's idea of a workspace.
///
/// `UserDefaults` and not the Keychain, because nothing here is a secret — a record is a
/// relay URL, a label, and the *names* of the two places this community's data sits. The
/// key itself never appears in it (§ ``Community``).
struct CommunityStorage {
    private let defaults: UserDefaults
    private let iconDirectory: URL?

    /// - Parameter defaults: injected so a test can drive a throwaway suite instead of the
    ///   app's own defaults, which a test run shares with whatever is installed.
    init(defaults: UserDefaults = .standard, iconDirectory: URL? = nil) {
        self.defaults = defaults
        self.iconDirectory = iconDirectory
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

    /// The cached bytes for a community's mark, or `nil` if the record predates icons or its
    /// file has already gone away.
    ///
    /// Reading a missing cache as no icon is intentional: the record still identifies the
    /// community and the next open can refresh it from the relay, while a damaged local file
    /// never prevents the switcher from drawing the initials fallback.
    func iconData(for community: Community) -> Data? {
        guard let filename = community.iconFilename,
              let directory = try? resolvedIconDirectory()
        else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(filename))
    }

    /// Replaces the cached icon and returns the directory record that names the new file.
    ///
    /// The file is written atomically before the returned record is saved by
    /// ``AppEnvironment/updateCommunities(_:)``. That order means a crash can leave an
    /// unused image file, but cannot leave a record pointing at a half-written image; the
    /// next refresh can safely replace it.
    func replacingIcon(_ data: Data?, for community: Community) throws -> Community {
        let directory = try resolvedIconDirectory()
        var updated = community
        if let data {
            let filename = community.iconFilename ?? "community-icon-\(community.id.uuidString).data"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            updated.iconFilename = filename
        } else {
            if let filename = community.iconFilename {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
            }
            updated.iconFilename = nil
        }
        return updated
    }

    /// Removes a community's cached mark when the community itself is removed.
    func removeIcon(for community: Community) {
        guard let filename = community.iconFilename,
              let directory = try? resolvedIconDirectory()
        else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    private func resolvedIconDirectory() throws -> URL {
        // Keep the cache beside the event store without depending on the composition root's
        // `@MainActor` helper. Storage is also used by non-UI tests and by the synchronous
        // launch migration, so this path lookup must remain a plain filesystem operation.
        let directory: URL
        if let iconDirectory {
            directory = iconDirectory
        } else {
            directory = try FileManager.default
                .url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("Hive", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
