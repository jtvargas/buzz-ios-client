import BuzzKit
import Foundation
import Observation

struct SearchSnapshot: Sendable, Hashable {
    let results: LocalSearchResults
    let directory: DirectorySnapshot
    let channels: [ChannelListRow]

    static let empty = SearchSnapshot(results: .empty, directory: .empty, channels: [])
}

struct SearchMessageResult: Sendable, Hashable, Identifiable {
    let id: String
    let channelID: String
    let pubkey: String
    let createdAt: Int64
    let content: String
    let matchRanges: [SearchMatchRange]
    let authorName: String?
    let authorPicture: String?
    let isDirectMessage: Bool

    init(_ hit: MessageSearchHit) {
        id = hit.id
        channelID = hit.channelID
        pubkey = hit.pubkey
        createdAt = hit.createdAt
        content = hit.content
        matchRanges = hit.matchRanges
        authorName = hit.authorName
        authorPicture = hit.authorPicture
        isDirectMessage = hit.isDirectMessage
    }

    init(_ hit: RelayMessageSearchHit) {
        id = hit.id
        channelID = hit.channelID
        pubkey = hit.pubkey
        createdAt = hit.createdAt
        content = hit.content
        matchRanges = hit.matchRanges
        authorName = nil
        authorPicture = nil
        isDirectMessage = false
    }
}

/// Owns one trailing-edge local search and rejects answers for text that has moved on.
@MainActor
@Observable
final class SearchModel {
    typealias Lookup = @Sendable (String) async throws -> SearchSnapshot
    typealias RelayLookup = @Sendable (String) async throws -> [RelayMessageSearchHit]

    private(set) var current = ""
    private(set) var results: LocalSearchResults = .empty
    private(set) var directory: DirectorySnapshot = .empty
    private(set) var channels: [ChannelListRow] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var errorMessage: String?

    var messages: [SearchMessageResult] {
        let local = results.messages.map(SearchMessageResult.init)
        let localIDs = Set(local.map(\.id))
        let relay = relayMessages
            .filter { !localIDs.contains($0.id) }
            .sorted { $0.ordinal < $1.ordinal }
            .map(SearchMessageResult.init)
        return local + relay
    }

    private let debounce: Duration
    private let lookup: Lookup
    private let relayLookup: RelayLookup?
    private var task: Task<Void, Never>?
    private var relayMessages: [RelayMessageSearchHit] = []

    init(
        store: BuzzEventStore,
        selfPubkey: String?,
        engine: SyncEngine? = nil,
        debounce: Duration = .milliseconds(300),
        lookup: Lookup? = nil,
        relayLookup: RelayLookup? = nil
    ) {
        self.debounce = debounce
        self.lookup = lookup ?? Self.liveLookup(store: store, selfPubkey: selfPubkey)
        if let relayLookup {
            self.relayLookup = relayLookup
        } else if let engine {
            self.relayLookup = { query in
                try await engine.searchRelayMessages(query: query)
            }
        } else {
            self.relayLookup = nil
        }
    }

    /// Schedules a trailing search. Repeating the current text is a true no-op: the guard
    /// precedes cancellation so a view update cannot kill a legitimate in-flight lookup.
    func search(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != current else { return }
        schedule(query, after: debounce)
    }

    /// Runs the field's submitted value now. An identical completed search remains a no-op;
    /// an identical lookup still inside its debounce is replaced by the immediate one.
    func submit(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != current || isSearching else { return }
        schedule(query, after: .zero)
    }

    private func schedule(_ query: String, after wait: Duration) {
        task?.cancel()
        task = nil
        current = query
        errorMessage = nil

        guard query.count >= 2 else {
            results = .empty
            relayMessages = []
            isSearching = false
            hasSearched = false
            return
        }

        // Before the wait: the old rows stay visible, but they never read as the answer to
        // the new text while its trailing-edge search is pending.
        isSearching = true
        let lookup = lookup
        let relayLookup = relayLookup
        // `query` is a call-site snapshot. Reading `current` inside this closure would make
        // the stale-answer guard below a tautology after a later keystroke.
        task = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, !Task.isCancelled else { return }
            await self.run(query, lookup: lookup, relayLookup: relayLookup)
        }
    }

    private func run(_ query: String, lookup: Lookup, relayLookup: RelayLookup?) async {
        let relayTask = relayLookup.map { relayLookup in
            Task { try await relayLookup(query) }
        }
        defer { relayTask?.cancel() }

        do {
            let snapshot = try await lookup(query)
            guard !Task.isCancelled, current == query else { return }
            results = snapshot.results
            relayMessages = []
            directory = snapshot.directory
            channels = snapshot.channels
            hasSearched = true
            guard let relayTask else { return finish() }
            await mergeRelay(from: relayTask, query: query)
        } catch {
            guard !Task.isCancelled, current == query else { return }
            isSearching = false
            hasSearched = true
            errorMessage = "Search is unavailable right now."
            task = nil
        }
    }

    private func mergeRelay(
        from relayTask: Task<[RelayMessageSearchHit], Error>,
        query: String
    ) async {
        do {
            let relay = try await relayTask.value
            guard !Task.isCancelled, current == query else { return }
            relayMessages = relay
        } catch {
            // Local search is the feature; a disconnected relay only removes reach beyond
            // this device and must not turn a valid offline answer into an error.
        }
        guard !Task.isCancelled, current == query else { return }
        finish()
    }

    private func finish() {
        isSearching = false
        task = nil
    }

    private nonisolated static func liveLookup(
        store: BuzzEventStore,
        selfPubkey: String?
    ) -> Lookup {
        { query in
            guard let selfPubkey else { return .empty }
            return try await Task.detached(priority: .userInitiated) {
                SearchSnapshot(
                    results: try store.searchLocal(query: query, selfPubkey: selfPubkey),
                    directory: try store.directorySnapshot(selfPubkey: selfPubkey),
                    channels: try store.channelList(selfPubkey: selfPubkey)
                )
            }.value
        }
    }
}
