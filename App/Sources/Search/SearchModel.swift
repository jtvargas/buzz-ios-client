import BuzzKit
import Foundation
import Observation

/// One database read: the message hits, plus the names and rooms needed to draw them.
///
/// The directory and the channel list do not depend on the query. They travel with it
/// because a result row has to name its author and its conversation, and because the
/// channel list is also the membership set the relay hits are filtered against.
struct SearchSnapshot: Sendable, Hashable {
    let messages: [MessageSearchHit]
    let directory: DirectorySnapshot
    let channels: [ChannelListRow]

    static let empty = SearchSnapshot(messages: [], directory: .empty, channels: [])
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
    /// The thread this message lives inside when it lives *only* there — see
    /// ``BuzzKit/MessageSearchHit/threadRootID``. It decides which surface a tap opens.
    let threadRootID: String?
    /// Whether opening this result has to read history off the relay before it can land.
    ///
    /// True for exactly the hits the *relay's* index answered and this device's did not — the
    /// message is not in the local log, so the reach has to page back to it over the network,
    /// which is the one path that is slow and the one that can fail. A hit this device already
    /// holds is a walk over local pages and lands about as fast as the screen opens.
    ///
    /// It earns a marker on the row because it changes what the reader should expect from the
    /// tap, and because it is the case where copying the link is the better move.
    let needsHistoryFetch: Bool

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
        threadRootID = hit.threadRootID
        needsHistoryFetch = false
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
        // The relay's search answers with event ids and nothing about threading, and this
        // device has not stored the message — so there is no thread row to consult either.
        // A relay-only reply therefore opens its channel and is paged for; when it turns out
        // not to be there, the surface says so rather than pretending. Settling that
        // properly means fetching the message before deciding, which is its own step.
        threadRootID = nil
        needsHistoryFetch = true
    }
}

/// Owns one trailing-edge local search and rejects answers for text that has moved on.
@MainActor
@Observable
final class SearchModel {
    typealias Lookup = @Sendable (String) async throws -> SearchSnapshot
    typealias RelayLookup = @Sendable (String) async throws -> [RelayMessageSearchHit]

    private(set) var current = ""
    private(set) var localMessages: [MessageSearchHit] = []
    private(set) var directory: DirectorySnapshot = .empty
    private(set) var channels: [ChannelListRow] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var errorMessage: String?

    /// Local hits first, then whatever the relay reached that this device had not stored.
    ///
    /// A relay hit is dropped unless its channel is in ``channels`` — the rooms this
    /// identity has joined and not archived. The relay answers a NIP-50 search from
    /// everything it will show us, so a hit can name a conversation this device cannot
    /// open: tapping it would push a screen that stays empty forever. A *local* hit needs
    /// no such filter, because the message being in the local log is what makes the
    /// conversation openable.
    var messages: [SearchMessageResult] {
        let local = localMessages.map(SearchMessageResult.init)
        let localIDs = Set(local.map(\.id))
        let joined = Set(channels.map(\.id))
        let relay = relayMessages
            .filter { !localIDs.contains($0.id) && joined.contains($0.channelID) }
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
            localMessages = []
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
            localMessages = snapshot.messages
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
                    messages: try store.searchMessages(query: query),
                    directory: try store.directorySnapshot(selfPubkey: selfPubkey),
                    channels: try store.channelList(selfPubkey: selfPubkey)
                )
            }.value
        }
    }
}
