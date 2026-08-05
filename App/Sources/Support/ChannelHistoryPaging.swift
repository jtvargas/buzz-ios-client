import BuzzKit

/// The one older page a timeline needs when the reader scrolls past the oldest row
/// this device holds — the narrow slice of ``SyncEngine`` that fetches it from the
/// relay and ingests it.
///
/// Behind a protocol for the reasons ``ThreadOpening`` is: the model depends on the
/// intent rather than the whole engine actor, and a test or a fixture can supply one
/// (or none). ``SyncEngine`` already exposes exactly this method, so the conformance
/// is free.
///
/// Optional at every call site. A surface built without one — the fixtures, the UI
/// tests — pages its local store and stops there, which is what it did before this
/// existed.
protocol ChannelHistoryPaging: Sendable {
    @discardableResult
    func loadOlderHistory(channel: String, before floor: WindowCursor) async throws -> SyncEngine.OlderHistoryPage
}

extension SyncEngine: ChannelHistoryPaging {}
