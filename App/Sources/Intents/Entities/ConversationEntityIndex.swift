import AppIntents
import BuzzKit
import CoreSpotlight
import Foundation
import Observation

/// The visible lifecycle of the active community's semantic-index pass.
enum IndexingState: Equatable {
    case off
    case idle
    case indexing
    case indexed(count: Int, at: Date)
    case failed(String)
}

/// Owns Hive's one active-community Conversation index and its live refresh.
///
/// # Every pass runs alone, and they run in the order they were asked for
///
/// Each hook suspends on a Core Spotlight round trip, so without ordering a teardown landing
/// mid-pass is *silently undone*: the pass resumes and re-publishes everything the teardown
/// just removed. That is reachable by hand — two taps on the Settings toggle inside a second
/// are two unstructured tasks — and it fails toward the wrong side, leaving a community's
/// channel names in Spotlight under a switch that reads off.
///
/// So the four hooks do not run their own work. They append it to ``work``, a chain in which
/// each task awaits its predecessor, and the enqueue itself happens with no suspension in
/// between — so the order passes run in is the order they were requested in, whatever order
/// the calling tasks happen to start in. Last request wins because it runs last, not because
/// anything raced.
///
/// Two consequences worth stating, since they are what let the callers stop waiting:
///
/// - ``teardown(nextState:)`` is the one hook that **awaits its own entry**. Everything before
///   it in the chain reads the store, and `teardownSession()` releases the store the moment
///   this returns, so draining is what keeps a pass from outliving the database it reads.
/// - The others return as soon as the work is queued. Ordering no longer depends on the caller
///   awaiting, which is what keeps a Core Spotlight round trip off the launch path and off the
///   websocket's.
@MainActor
@Observable
final class ConversationEntityIndex {
    private(set) var state: IndexingState = .idle

    private let snapshots: ConversationEntitySnapshotStore
    private var refreshTask: Task<Void, Never>?
    private var work: Task<Void, Never> = Task {}

    init(
        snapshots: ConversationEntitySnapshotStore = ConversationEntitySnapshotStore()
    ) {
        self.snapshots = snapshots
    }

    /// Hook 0: privacy cleanup before launch can stop at an identity gate or failure screen.
    /// It deliberately leaves `state` alone; there is not yet an active community to report.
    func reconcileLaunch() {
        stopObserving()
        enqueue { [self] in
            snapshots.clear()
            try? await Self.deleteAll()
            HiveShortcuts.updateAppShortcutParameters()
        }
    }

    /// Hook 1: publishes a successful session's current channels, then follows its store.
    func rebuild(store: BuzzEventStore, selfPubkey: String?, community: Community) {
        stopObserving()
        guard community.isSiriIndexingEnabled else {
            state = .off
            return
        }
        enqueue { [self] in
            await indexCurrent(store: store, selfPubkey: selfPubkey, community: community, forcePhrases: true)
        }
        observeChanges(in: store, selfPubkey: selfPubkey, community: community)
    }

    /// Hook 3: replaces the whole small set so a leave or archive cannot strand one entity.
    func refresh(store: BuzzEventStore, selfPubkey: String?, community: Community) {
        enqueue { [self] in
            await indexCurrent(store: store, selfPubkey: selfPubkey, community: community, forcePhrases: false)
        }
    }

    /// Hook 2: removes every entity of Hive's type before the outgoing store is released.
    ///
    /// Awaits the whole chain, so no earlier pass is still holding the store when this returns.
    func teardown(nextState: IndexingState = .idle) async {
        stopObserving()
        await enqueue { [self] in
            snapshots.clear()
            do {
                try await Self.deleteAll()
                state = nextState
                HiveShortcuts.updateAppShortcutParameters()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }.value
    }

    /// Appends one pass to the chain. Synchronous to its caller by construction: a hook must be
    /// able to take its place in the queue without suspending, or two hooks racing to enqueue
    /// would settle in an order unrelated to the order they were called in.
    @discardableResult
    private func enqueue(_ pass: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = work
        let next = Task { @MainActor in
            await previous.value
            await pass()
        }
        work = next
        return next
    }

    private func stopObserving() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Core Spotlight

    // `CSSearchableIndex` is not `Sendable`, and both entry points are `nonisolated async` — so
    // an index held as a property of this `@MainActor` type cannot be handed to them without
    // "sending risks causing data races". Building it inside a `nonisolated` function keeps the
    // object in one isolation domain for its whole life, which is what the compiler is asking
    // for. `.default()` in both, so index and delete address the same index (Apple's own entity
    // sample does the same, against a reference page that prefers named indexes).
    //
    // No wrapper type: this needs *ordering*, not isolation, and ordering is ``work``'s job. An
    // earlier draft wrapped these in an actor whose doc comment promised serialisation — actors
    // are re-entrant, so awaiting inside one orders nothing, and the comment would have been
    // the guarantee somebody leaned on.

    private nonisolated static func deleteAll() async throws {
        try await CSSearchableIndex.default().deleteAppEntities(ofType: ConversationEntity.self)
    }

    private nonisolated static func publish(_ entities: [ConversationEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    private func indexCurrent(
        store: BuzzEventStore,
        selfPubkey: String?,
        community: Community,
        forcePhrases: Bool
    ) async {
        let published = snapshots.load().flatMap { $0.communityID == community.id ? $0.entries : nil }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps on a repeated
        // key, and a duplicate channel row would turn a stale index into a crash.
        let previousPairs = Dictionary(
            (published ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
        )
        do {
            let entities = try Self.entities(in: store, selfPubkey: selfPubkey, communityID: community.id)
            let entries = entities.map(ConversationEntitySnapshotStore.Entry.init)
            // The coalesced signal fires on every stored event — every message anybody sends —
            // while the channel set changes on a join or a leave, days apart. Republishing an
            // identical set would rewrite Spotlight per message and flicker the status row
            // through `.indexing` each time, so an unchanged refresh does nothing at all.
            // A session start still republishes unconditionally: that is the pass covering a
            // projection rebuild, which changes no `event` row and so reaches here as "same".
            if !forcePhrases, published == entries { return }
            let nextPairs = Dictionary(
                entries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
            state = .indexing
            // Persisted before the first suspension, not between the two calls. Hook 0 clears
            // the snapshot on every launch, and `phase = .running` is set ahead of this pass —
            // so an intent's push can land while it is in flight, and a snapshot restored only
            // after the delete round trip leaves that push with no name to draw. It is also
            // the safer end to be interrupted at: a snapshot naming channels Spotlight has not
            // published yet resolves conversations that genuinely exist.
            snapshots.save(communityID: community.id, entities: entities)
            try await Self.deleteAll()
            try await Self.publish(entities)
            state = .indexed(count: entities.count, at: Date())
            if forcePhrases || previousPairs != nextPairs {
                HiveShortcuts.updateAppShortcutParameters()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func observeChanges(in store: BuzzEventStore, selfPubkey: String?, community: Community) {
        refreshTask = Task { [weak self] in
            var isInitialEmission = true
            do {
                for try await _ in DatabaseSignal.coalescedChanges(in: store.reader) {
                    if isInitialEmission {
                        isInitialEmission = false
                        continue
                    }
                    try await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self?.refresh(store: store, selfPubkey: selfPubkey, community: community)
                }
            } catch is CancellationError {
                return
            } catch {
                // A teardown cancels this task and then `teardownSession()` drops the store, so
                // the stream can surface the close as a plain database error rather than a
                // cancellation. Reporting that would put SQLite's words in orange under a Siri
                // toggle during an ordinary community switch — an ended observation is not a
                // failed index.
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    private static func entities(
        in store: BuzzEventStore,
        selfPubkey: String?,
        communityID: Community.ID
    ) throws -> [ConversationEntity] {
        try store.channelList(selfPubkey: selfPubkey).compactMap { row in
            guard !row.isDirectMessage,
                  let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return ConversationEntity(
                id: EntityID(community: communityID, native: row.id),
                name: name,
                isPrivate: row.isPrivate
            )
        }
    }
}
