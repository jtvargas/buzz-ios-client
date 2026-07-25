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
