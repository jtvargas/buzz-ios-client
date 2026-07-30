import BuzzKit

/// The bounded reply fetch a screen asks for on arrival — the narrow slice of
/// ``SyncEngine`` that fills in the threads this device is behind on.
///
/// Behind a protocol for the reason every other seam here is: a screen should depend on
/// the intent rather than on the whole engine actor, and a test that arrives on a screen
/// should be able to assert what it asked for without a relay socket underneath it.
/// ``SyncEngine`` already exposes exactly this method, so the conformance is free.
///
/// Both surfaces that use it hold it as an *optional*, unlike `MessageSending` or
/// `ThreadOpening`. That is deliberate and is the opposite of the reasoning behind
/// ``ThreadsView``'s non-defaulted `openedThread`: a missing prefetcher costs a screen
/// nothing but freshness, while the UI-test hosts that drive these screens
/// (``ConversationFixtureHost``) must not reach a network at all, and a required
/// collaborator there would have to be a no-op double that says the same thing at more
/// length.
protocol ThreadPrefetching: Sendable {
    /// - Parameter channel: Restrict to one channel's threads, or `nil` for every channel.
    func prefetchThreads(in channel: String?) async
}

extension SyncEngine: ThreadPrefetching {}
