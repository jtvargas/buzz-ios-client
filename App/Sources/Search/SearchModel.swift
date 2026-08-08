import BuzzKit
import Foundation
import Observation

struct SearchSnapshot: Sendable, Hashable {
    let results: LocalSearchResults
    let directory: DirectorySnapshot
    let channels: [ChannelListRow]

    static let empty = SearchSnapshot(results: .empty, directory: .empty, channels: [])
}

/// Owns one trailing-edge local search and rejects answers for text that has moved on.
@MainActor
@Observable
final class SearchModel {
    typealias Lookup = @Sendable (String) async throws -> SearchSnapshot

    private(set) var current = ""
    private(set) var results: LocalSearchResults = .empty
    private(set) var directory: DirectorySnapshot = .empty
    private(set) var channels: [ChannelListRow] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var errorMessage: String?

    private let debounce: Duration
    private let lookup: Lookup
    private var task: Task<Void, Never>?

    init(
        store: BuzzEventStore,
        selfPubkey: String?,
        debounce: Duration = .milliseconds(300),
        lookup: Lookup? = nil
    ) {
        self.debounce = debounce
        self.lookup = lookup ?? Self.liveLookup(store: store, selfPubkey: selfPubkey)
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
            isSearching = false
            hasSearched = false
            return
        }

        // Before the wait: the old rows stay visible, but they never read as the answer to
        // the new text while its trailing-edge search is pending.
        isSearching = true
        let lookup = lookup
        // `query` is a call-site snapshot. Reading `current` inside this closure would make
        // the stale-answer guard below a tautology after a later keystroke.
        task = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await lookup(query)
                guard let self, !Task.isCancelled, self.current == query else { return }
                self.results = snapshot.results
                self.directory = snapshot.directory
                self.channels = snapshot.channels
                self.isSearching = false
                self.hasSearched = true
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.current == query else { return }
                self.isSearching = false
                self.hasSearched = true
                self.errorMessage = "Search is unavailable right now."
                self.task = nil
            }
        }
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
