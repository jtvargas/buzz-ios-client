import BuzzKit
@testable import Hive
import NostrCore

/// A ``ThreadOpening`` double standing in for `engine.openThread`: on open it
/// ingests a scripted set of replies into the store, exactly as the engine's
/// one-shot fetch would, so a thread model test can prove the open path fills the
/// thread before it then ingests further replies live.
struct StubThreadOpener: ThreadOpening {
    let store: BuzzEventStore
    let events: [NostrEvent]

    @discardableResult
    func openThread(root _: String) async throws -> [NostrEvent] {
        _ = try await store.ingest(batch: events, phase: .backfill)
        return events
    }
}

/// A ``ThreadOpening`` double whose one-shot fetch never returns until the task is
/// cancelled — standing in for a slow (or stalled) relay round-trip. It proves the
/// thread model renders the store's local rows without waiting on the network fetch:
/// were the observation still gated on the fetch, the rows would stay empty.
struct BlockingThreadOpener: ThreadOpening {
    @discardableResult
    func openThread(root _: String) async throws -> [NostrEvent] {
        try await Task.sleep(for: .seconds(3600))
        return []
    }
}
