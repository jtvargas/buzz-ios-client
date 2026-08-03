import Foundation
@testable import Hive
import Testing

/// Persistence of the community list, and the migration that turns the install this app
/// used to be into community #1 without moving anything.
///
/// Serialized because the adoption reads the two globals the single-community app wrote:
/// the relay URL and the recorded store owner, both in the standard defaults.
@Suite(.serialized)
struct CommunityStorageTests {
    /// A throwaway defaults suite, so a test run never writes over the list of whatever
    /// build is installed on the machine.
    private func makeStorage() -> (storage: CommunityStorage, suite: String) {
        let name = "hive.tests.communities.\(UUID().uuidString)"
        return (CommunityStorage(defaults: UserDefaults(suiteName: name)!), name)
    }

    /// Throws the suite away. Named rather than inlined because every test here has to do
    /// it, and a leaked suite is a file left in the simulator's preferences for ever.
    private func forget(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func aFreshInstallHasNoCommunities() {
        let (storage, suite) = makeStorage()
        defer { forget(suite) }
        #expect(storage.load().isEmpty)
        #expect(storage.load().active == nil)
    }

    @Test func roundTripsTheListAndWhichOneIsBeingRead() {
        let (storage, suite) = makeStorage()
        defer { forget(suite) }

        var directory = CommunityDirectory()
        let first = Community.new(relayURLString: "wss://a.example", name: "Alpha")
        let second = Community.new(relayURLString: "wss://b.example", name: "Beta")
        directory.add(first)
        directory.add(second)
        directory.setActive(second.id)
        storage.save(directory)

        let loaded = storage.load()
        #expect(loaded.communities.map(\.name) == ["Alpha", "Beta"])
        #expect(loaded.activeID == second.id)
        // The storage each community names has to survive the round trip: it is how its
        // key and its history are found again.
        #expect(loaded.communities[0].keychainAccount == first.keychainAccount)
        #expect(loaded.communities[0].storeFilename == first.storeFilename)
    }

    @Test func anIconSurvivesARecordAndFileRoundTrip() throws {
        let suite = "hive.tests.communities.icon.\(UUID().uuidString)"
        let iconDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-community-icons-\(UUID().uuidString)", isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let storage = CommunityStorage(defaults: defaults, iconDirectory: iconDirectory)
        let community = Community.new(relayURLString: "wss://icons.example", name: "Icons")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: iconDirectory)
        }

        let withIcon = try storage.replacingIcon(bytes, for: community)
        var directory = CommunityDirectory()
        directory.add(withIcon)
        storage.save(directory)

        let loaded = try #require(storage.load().communities.first)
        #expect(loaded.iconFilename == withIcon.iconFilename)
        #expect(storage.iconData(for: loaded) == bytes)
    }

    @Test func clearingForgetsEverything() {
        let (storage, suite) = makeStorage()
        defer { forget(suite) }
        var directory = CommunityDirectory()
        directory.add(Community.new(relayURLString: "wss://a.example"))
        storage.save(directory)
        storage.clear()
        #expect(storage.load().isEmpty)
    }

    // MARK: - Adopting the single-community install

    @Test func adoptsTheInstallThatPredatesTheList() throws {
        let (storage, suite) = makeStorage()
        let previousRelay = RelayEndpoint.storedURLString
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        RelayEndpoint.storedURLString = "wss://hive.example.ts.net"

        let directory = storage.loadAdoptingLegacyInstall(hasLegacyIdentity: true)
        #expect(directory.communities.count == 1)
        let adopted = try #require(directory.active)
        #expect(adopted.relayURLString == "wss://hive.example.ts.net")
        // Nothing moved: the key stays where the signer already looks and the history stays
        // in the file the store already has open.
        #expect(adopted.keychainAccount == Community.legacyKeychainAccount)
        #expect(adopted.storeFilename == Community.legacyStoreFilename)
    }

    @Test func adoptionIsDurableAndHappensOnce() {
        let (storage, suite) = makeStorage()
        let previousRelay = RelayEndpoint.storedURLString
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        RelayEndpoint.storedURLString = "wss://hive.example.ts.net"

        let first = storage.loadAdoptingLegacyInstall(hasLegacyIdentity: true)
        let second = storage.loadAdoptingLegacyInstall(hasLegacyIdentity: true)
        #expect(second.communities.count == 1)
        // The same record, not a second one wearing the same relay: a fresh id here would
        // mean a fresh Keychain account and a fresh database on every launch.
        #expect(second.communities.first?.id == first.communities.first?.id)
    }

    @Test func aDeviceWithNoIdentityAdoptsNothing() {
        let (storage, suite) = makeStorage()
        defer { forget(suite) }
        #expect(storage.loadAdoptingLegacyInstall(hasLegacyIdentity: false).isEmpty)
    }

    // MARK: - Where a community's history lives

    /// One file per community, opened by the name its record carries — the isolation the
    /// whole feature rests on. A shared file with a community column would put that
    /// isolation in every query in BuzzKit, where one missing `WHERE` shows another
    /// community's messages.
    @MainActor
    @Test func eachCommunityOpensADatabaseOfItsOwn() throws {
        let first = "hive-tests-\(UUID().uuidString).sqlite"
        let second = "hive-tests-\(UUID().uuidString).sqlite"
        defer {
            AppEnvironment.deleteStore(filename: first)
            AppEnvironment.deleteStore(filename: second)
        }
        let directory = try AppEnvironment.storeDirectory()

        _ = try AppEnvironment.makeStore(filename: first)
        _ = try AppEnvironment.makeStore(filename: second)

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(second).path))
    }

    /// Removing a community takes the write-ahead log and shared-memory file with it. A
    /// `-wal` left behind holds committed pages the main file never received, and a later
    /// database of the same name would be asked to recover from it.
    @MainActor
    @Test func removingACommunityLeavesNoneOfItsDatabaseBehind() throws {
        let filename = "hive-tests-\(UUID().uuidString).sqlite"
        let directory = try AppEnvironment.storeDirectory()
        defer { AppEnvironment.deleteStore(filename: filename) }
        _ = try AppEnvironment.makeStore(filename: filename)
        for suffix in ["-wal", "-shm"] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(filename + suffix).path,
                contents: Data()
            )
        }

        AppEnvironment.deleteStore(filename: filename)

        for suffix in ["", "-wal", "-shm"] {
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(filename + suffix).path
                )
            )
        }
    }

    @Test func adoptionNeverRunsOverAListThatAlreadyExists() {
        let (storage, suite) = makeStorage()
        let previousRelay = RelayEndpoint.storedURLString
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        RelayEndpoint.storedURLString = "wss://hive.example.ts.net"

        var directory = CommunityDirectory()
        directory.add(Community.new(relayURLString: "wss://a.example", name: "Alpha"))
        storage.save(directory)

        let loaded = storage.loadAdoptingLegacyInstall(hasLegacyIdentity: true)
        #expect(loaded.communities.map(\.name) == ["Alpha"])
    }
}
