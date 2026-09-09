import Foundation
import NostrCore

/// Everything the app subscribes to on the engine.
///
/// Lifted out of ``SyncEngine``'s own body, which sits at swiftlint's 350-line ceiling
/// for a type: adding the send-confirmation feed pushed it over, and the subscription
/// surface was the coherent piece to move rather than an arbitrary slice. The
/// continuations themselves stay in the actor's body — a stored property cannot live in
/// an extension — which is why they are `internal` rather than `private` there.
///
/// Each feed is the same three lines of bookkeeping: hand out a stream, remember its
/// continuation under an id, and drop it when the consumer goes away. Two of them are
/// *seeded* with the current value and two are not, and that difference is the whole
/// design decision in this file — see each one.
extension SyncEngine {
    /// A live feed of engine state, seeded with the current value so a new observer
    /// never misses the state it subscribed in.
    public func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        let id = nextObserverID
        nextObserverID += 1
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(id) }
        }
        return stream
    }

    /// A live feed of directory authority, seeded with the current value so the
    /// app can choose its launch or recovery surface without a transient default.
    public func channelDirectoryStatuses() -> AsyncStream<ChannelDirectoryStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChannelDirectoryStatus.self)
        let id = nextDirectoryStatusObserverID
        nextDirectoryStatusObserverID += 1
        directoryStatusObservers[id] = continuation
        continuation.yield(directoryContext?.status ?? .authoritative)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDirectoryStatusObserver(id) }
        }
        return stream
    }

    /// IDs inserted from the standing subscription after its stored-event boundary.
    /// Backfill and reconciliation never enter this stream, which makes it the app's
    /// authoritative seam for foreground-only new-message presentation.
    public func liveMessageInsertions() -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let id = nextLiveMessageObserverID
        nextLiveMessageObserverID += 1
        liveMessageObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLiveMessageObserver(id) }
        }
        return stream
    }

    func publishLiveMessageInsertions(_ eventIDs: [String]) {
        guard !eventIDs.isEmpty else { return }
        for continuation in liveMessageObservers.values {
            continuation.yield(eventIDs)
        }
    }

    /// Events this device sent that the relay has acknowledged, in the order they were
    /// confirmed.
    ///
    /// The seam for anything that has to know a send *landed* rather than that it was
    /// queued — the outbox row is gone and the log row exists by the time this yields
    /// (``BuzzEventStore/confirmSent(_:)``). Not seeded, unlike ``states()``: a
    /// subscriber learns about the sends made while it was listening and nothing else,
    /// which is what a reaction to a send wants.
    ///
    /// Every kind goes through it, reactions and deletions included; filtering is the
    /// subscriber's. A resend the relay answers `duplicate:` is confirmed inside the
    /// store's rejection policy rather than on this path, so a send already acknowledged
    /// once does not yield twice.
    public func sentConfirmations() -> AsyncStream<NostrEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: NostrEvent.self)
        let id = nextSentConfirmationObserverID
        nextSentConfirmationObserverID += 1
        sentConfirmationObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSentConfirmationObserver(id) }
        }
        return stream
    }

    func publishSentConfirmation(_ event: NostrEvent) {
        for continuation in sentConfirmationObservers.values {
            continuation.yield(event)
        }
    }

    private func removeStateObserver(_ id: Int) {
        stateObservers.removeValue(forKey: id)
    }

    private func removeDirectoryStatusObserver(_ id: Int) {
        directoryStatusObservers.removeValue(forKey: id)
    }

    private func removeLiveMessageObserver(_ id: Int) {
        liveMessageObservers.removeValue(forKey: id)
    }

    private func removeSentConfirmationObserver(_ id: Int) {
        sentConfirmationObservers.removeValue(forKey: id)
    }
}
