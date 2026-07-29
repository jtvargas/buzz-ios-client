import BuzzKit

/// The catch-up a pull-to-refresh asks for — the narrow slice of ``SyncEngine`` a
/// screen with a refresh control depends on.
///
/// Behind a protocol for the reason every other seam here is: a screen should depend
/// on the intent rather than on the whole engine actor, and a test that pulls to
/// refresh should be able to assert the pull without a relay socket underneath it.
/// ``SyncEngine`` already exposes exactly this method, so the conformance is free.
protocol ConversationRefreshing: Sendable {
    func refresh() async
}

extension SyncEngine: ConversationRefreshing {}
