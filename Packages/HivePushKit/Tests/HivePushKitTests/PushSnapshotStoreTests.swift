import Foundation
@testable import HivePushKit
import Testing

/// The App Group hand-off between the app and its extension, driven against a
/// throwaway container directory: what the app writes is what the extension
/// reads, a rename replaces rather than duplicates, and the two removals —
/// one community, or all of them on sign-out — leave nothing for the extension
/// to act on.
@Suite("Push snapshot store")
struct PushSnapshotStoreTests {
    /// A store over a fresh container, and the directory to delete afterwards.
    private func makeStore() -> (PushSnapshotStore, URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("HivePushKitTests-\(UUID().uuidString)", isDirectory: true)
        return (PushSnapshotStore(containerURL: container), container)
    }

    private func snapshot(
        communityID: String = UUID().uuidString,
        name: String = "Hive",
        version: Int = PushCommunitySnapshot.currentVersion
    ) -> PushCommunitySnapshot {
        PushCommunitySnapshot(
            version: version,
            communityID: communityID,
            name: name,
            relayURL: URL(string: "wss://relay.example/ws")!,
            gatewayURL: URL(string: "https://relay.example")!,
            keychainAccount: "hive.identity.\(communityID)",
            // Whole seconds: the file carries ISO 8601, which drops the fraction, and the
            // round-trip below compares the whole value.
            updatedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    @Test("A written snapshot reads back whole, by community id")
    func writeThenRead() throws {
        let (store, container) = makeStore()
        defer { try? FileManager.default.removeItem(at: container) }
        let written = snapshot()

        try store.write(written)

        #expect(try store.load(communityID: written.communityID) == written)
        #expect(try store.loadAll() == [written])
    }

    @Test("Nothing stored reads as nil, not as an error")
    func absentReadsNil() throws {
        let (store, container) = makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(try store.load(communityID: UUID().uuidString) == nil)
        #expect(try store.loadAll() == [])
    }

    @Test("Rewriting a community replaces its snapshot rather than adding a second")
    func renameUpdatesInPlace() throws {
        let (store, container) = makeStore()
        defer { try? FileManager.default.removeItem(at: container) }
        let before = snapshot(name: "Hive")
        let after = snapshot(communityID: before.communityID, name: "Work")

        try store.write(before)
        try store.write(after)

        #expect(try store.load(communityID: before.communityID)?.name == "Work")
        #expect(try store.loadAll() == [after])
    }

    @Test("Removing one community leaves the others in place")
    func removeOne() throws {
        let (store, container) = makeStore()
        defer { try? FileManager.default.removeItem(at: container) }
        let leaving = snapshot(name: "Leaving")
        let staying = snapshot(name: "Staying")
        try store.write(leaving)
        try store.write(staying)

        try store.remove(communityID: leaving.communityID)

        #expect(try store.load(communityID: leaving.communityID) == nil)
        #expect(try store.loadAll() == [staying])
        // A second removal of the same community, or of one never written, is not an error.
        try store.remove(communityID: leaving.communityID)
        try store.remove(communityID: UUID().uuidString)
    }

    @Test("Sign-out clears every snapshot, and the store is writable again afterwards")
    func removeAllOnSignOut() throws {
        let (store, container) = makeStore()
        defer { try? FileManager.default.removeItem(at: container) }
        try store.write(snapshot())
        try store.write(snapshot())

        try store.removeAll()

        #expect(try store.loadAll() == [])
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        // An absent store is cleared without error, and the next session can write into it.
        try store.removeAll()
        let next = snapshot()
        try store.write(next)
        #expect(try store.load(communityID: next.communityID) == next)
    }

    @Test("A snapshot of another version is dropped rather than guessed at")
    func unreadableVersionIsSkipped() throws {
        let (store, container) = makeStore()
        defer { try? FileManager.default.removeItem(at: container) }
        let foreign = snapshot(version: PushCommunitySnapshot.currentVersion + 1)
        let current = snapshot()
        try store.write(foreign)
        try store.write(current)

        #expect(try store.load(communityID: foreign.communityID) == nil)
        #expect(try store.loadAll() == [current])
    }
}
