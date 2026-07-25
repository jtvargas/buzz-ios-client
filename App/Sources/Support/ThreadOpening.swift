import BuzzKit
import NostrCore

/// The one-shot thread fetch a ``ThreadModel`` needs on open — the narrow slice of
/// ``SyncEngine`` that pulls a thread's replies by root id and ingests them.
///
/// Behind a protocol so a thread model's open path is testable against a scripted
/// opener that ingests fixture replies, and so the model depends on an intent
/// rather than the whole engine actor. ``SyncEngine`` already exposes exactly this
/// method, so the conformance is free.
protocol ThreadOpening: Sendable {
    @discardableResult
    func openThread(root: String) async throws -> [NostrEvent]
}

extension SyncEngine: ThreadOpening {}
