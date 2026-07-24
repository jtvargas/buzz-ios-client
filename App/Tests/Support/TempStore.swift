import BuzzKit
import Foundation

/// A unique on-disk store for one test, opened through BuzzKit's public
/// `BuzzEventStore(path:)` — the same WAL `DatabasePool` the app opens, so the
/// observation tests exercise the shipping configuration. Call ``remove()`` from a
/// `defer`.
struct TempStore {
    let path: String

    init() {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-tests-\(UUID().uuidString).sqlite")
            .path
    }

    func open() throws -> BuzzEventStore {
        try BuzzEventStore(path: path)
    }

    func remove() {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(atPath: path + suffix)
        }
    }
}
