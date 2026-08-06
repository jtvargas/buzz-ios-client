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
/// So no hook performs its own Spotlight work. It appends it to ``work``, a chain in which each
/// task awaits its predecessor. Last request wins because it runs last, not because anything
/// raced.
///
/// # The split: the snapshot is written here, only Spotlight is queued
///
/// Each hook does its ``ConversationEntitySnapshotStore`` half **synchronously, at call time**,
/// and queues only the `CSSearchableIndex` calls. That is deliberate on both counts:
///
/// - The snapshot is what an intent's push reads for a name, and `phase = .running` is set in
///   the same turn as hook 1 — so a snapshot written inside a queued pass lands *after* the
///   sidebar has mounted and consumed the pending conversation. An earlier draft queued both
///   halves and put hook 0's clear and hook 1's save in different entries with an XPC round
///   trip between them, which left the flagship cold-launch push with no name to draw.
/// - Doing it at call time is also what orders the snapshot at all: MainActor, no suspension,
///   so the later caller wins in the snapshot exactly as it wins in the chain.
///
/// # No hook waits, including this one's teardown
///
/// Every entry point returns as soon as its work is queued, so a Core Spotlight round trip is
/// never on the launch path, in front of the websocket, or in the middle of a community switch.
/// Ordering does not depend on any caller awaiting — see ``teardown(nextState:)`` for why the
/// one wait that used to exist stopped buying anything once the store read moved out of the
/// queued half.
///
/// That makes every hook synchronous to its caller, which is worth more than it looks: the
/// Settings toggle can call straight through instead of spawning a task per tap, so the order
/// two taps are *made* in is the order they are enqueued in. The chain orders enqueues; without
/// that, it would only order whenever two unstructured tasks happened to start.
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
        snapshots.clear()
        enqueue {
            try? await Self.deleteAll()
            HiveShortcuts.updateAppShortcutParameters()
        }
    }

    /// Hook 1: publishes a successful session's current channels, then follows its store.
    func rebuild(store: BuzzEventStore, selfPubkey: String?, community: Community) {
        stopObserving()
        guard community.isSiriIndexingEnabled else {
            // The one write to `state` from outside a pass. Safe because nothing can be queued
            // at this moment — a switch drains through `teardown()` first, and on launch the
            // chain holds only hook 0, which leaves `state` alone by design. A fifth caller
            // would break that, so it is stated rather than left to be inferred.
            state = .off
            return
        }
        indexCurrent(store: store, selfPubkey: selfPubkey, community: community, forcePhrases: true)
        observeChanges(in: store, selfPubkey: selfPubkey, community: community)
    }

    /// Hook 3: replaces the whole small set so a leave or archive cannot strand one entity.
    func refresh(store: BuzzEventStore, selfPubkey: String?, community: Community) {
        indexCurrent(store: store, selfPubkey: selfPubkey, community: community, forcePhrases: false)
    }

    /// Hook 2: removes every entity of Hive's type as the outgoing store is released.
    ///
    /// **Does not wait**, deliberately, and an earlier revision did. Waiting was there to keep a
    /// queued pass from outliving the store it read — but once the derivation moved into the
    /// synchronous half, no queued closure touches the store at all: they call Core Spotlight,
    /// write `state`, and read the snapshot. So the wait was buying nothing and costing a real
    /// failure mode, since a wedged `corespotlightd` would have blocked every switch and every
    /// sign-out for as long as it stayed wedged.
    ///
    /// What waiting *did* still buy is named here rather than lost: without it, a switch can
    /// mount Y's workspace while a pass queued for X is still publishing, so X's channel names
    /// can sit in Spotlight for a moment under Y's sidebar. That is visibility only —
    /// `OpenConversationIntent.perform()` re-checks the live active community, so nothing
    /// opens — and §4 already accepts a far longer version of exactly this after an unclean
    /// exit. Ordering is unaffected either way: the chain runs old-build → teardown → new-build
    /// whether or not the caller waits.
    func teardown(nextState: IndexingState = .idle) {
        stopObserving()
        snapshots.clear()
        enqueue { [self] in
            do {
                try await Self.deleteAll()
                state = nextState
                HiveShortcuts.updateAppShortcutParameters()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
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

    /// Derives the set, writes the snapshot, and queues the Spotlight half.
    ///
    /// **Synchronous, and that is the point.** The snapshot is what an intent's push reads for a
    /// name, and `phase = .running` is set in the same turn as the call above — so a snapshot
    /// written inside a queued pass is written *after* the sidebar has already mounted and
    /// consumed the pending conversation, which is the untitled placeholder §8 added it to
    /// prevent. Queueing only the Core Spotlight calls keeps every snapshot write on the
    /// MainActor with no suspension in it, which is also what orders the snapshot against hook
    /// 0's clear: both happen at call time, so the later caller wins in both halves.
    private func indexCurrent(
        store: BuzzEventStore,
        selfPubkey: String?,
        community: Community,
        forcePhrases: Bool
    ) {
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
            let refreshesPhrases = forcePhrases || previousPairs != nextPairs
            snapshots.save(communityID: community.id, entities: entities)
            state = .indexing
            enqueue { [self] in
                do {
                    try await Self.deleteAll()
                    try await Self.publish(entities)
                    state = .indexed(count: entities.count, at: Date())
                    if refreshesPhrases { HiveShortcuts.updateAppShortcutParameters() }
                } catch {
                    state = .failed(error.localizedDescription)
                }
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
