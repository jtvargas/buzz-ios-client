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
@MainActor
@Observable
final class ConversationEntityIndex {
    private(set) var state: IndexingState = .idle

    private let searchableIndex: ConversationSearchableIndex
    private let snapshots: ConversationEntitySnapshotStore
    private var refreshTask: Task<Void, Never>?

    init(
        snapshots: ConversationEntitySnapshotStore = ConversationEntitySnapshotStore()
    ) {
        self.searchableIndex = ConversationSearchableIndex()
        self.snapshots = snapshots
    }

    /// Hook 0: privacy cleanup before launch can stop at an identity gate or failure screen.
    /// It deliberately leaves `state` alone; there is not yet an active community to report.
    func reconcileLaunch() async {
        refreshTask?.cancel()
        refreshTask = nil
        snapshots.clear()
        try? await searchableIndex.deleteAppEntities(ofType: ConversationEntity.self)
        HiveShortcuts.updateAppShortcutParameters()
    }

    /// Hook 1: publishes a successful session's current channels, then follows its store.
    func rebuild(store: BuzzEventStore, selfPubkey: String?, community: Community) async {
        refreshTask?.cancel()
        refreshTask = nil
        guard community.isSiriIndexingEnabled else {
            state = .off
            return
        }

        await indexCurrent(store: store, selfPubkey: selfPubkey, community: community, forcePhrases: true)
        observeChanges(in: store, selfPubkey: selfPubkey, community: community)
    }

    /// Hook 3: replaces the whole small set so a leave or archive cannot strand one entity.
    func refresh(store: BuzzEventStore, selfPubkey: String?, community: Community) async {
        await indexCurrent(store: store, selfPubkey: selfPubkey, community: community, forcePhrases: false)
    }

    /// Hook 2: removes every entity of Hive's type before the outgoing store is released.
    func teardown(nextState: IndexingState = .idle) async {
        refreshTask?.cancel()
        refreshTask = nil
        snapshots.clear()
        do {
            try await searchableIndex.deleteAppEntities(ofType: ConversationEntity.self)
            state = nextState
            HiveShortcuts.updateAppShortcutParameters()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func indexCurrent(
        store: BuzzEventStore,
        selfPubkey: String?,
        community: Community,
        forcePhrases: Bool
    ) async {
        let previousPairs = Dictionary(
            uniqueKeysWithValues: snapshots.load()?.entries.map { ($0.id, $0.name) } ?? []
        )
        do {
            let entities = try Self.entities(in: store, selfPubkey: selfPubkey, communityID: community.id)
            let nextPairs = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.name) })
            state = .indexing
            try await searchableIndex.deleteAppEntities(ofType: ConversationEntity.self)
            // Persist first: if the process dies while Spotlight accepts the batch, every
            // entity it may expose already has a cold-launch resolver and fallback row.
            snapshots.save(communityID: community.id, entities: entities)
            try await searchableIndex.indexAppEntities(entities)
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
                    await self?.refresh(store: store, selfPubkey: selfPubkey, community: community)
                }
            } catch is CancellationError {
                return
            } catch {
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

/// Serialises all access to Core Spotlight's non-Sendable index object.
private actor ConversationSearchableIndex {
    nonisolated(unsafe) private let index: CSSearchableIndex

    init() {
        self.index = .default()
    }

    func deleteAppEntities<T: IndexedEntity>(ofType type: T.Type) async throws {
        try await index.deleteAppEntities(ofType: type)
    }

    func indexAppEntities<T: IndexedEntity>(_ entities: [T]) async throws {
        try await index.indexAppEntities(entities)
    }
}
