import BuzzKit
import GRDB
import NostrCore
import Observation

/// What the app needs from the engine to join a channel.
///
/// A protocol for the same reason ``ChannelCreating`` is one: the substance here is the
/// states *around* the call — joining, its phases, the refusal turned into a sentence —
/// and a stub is how those are asserted without a relay. Not main-actor isolated, because
/// `SyncEngine` is an actor and an actor cannot conform to a globally isolated protocol.
protocol ChannelJoining: Sendable {
    /// Joins an open channel and returns once it is hydrated enough to open.
    func joinChannel(
        _ channelID: String,
        onProgress: @Sendable @escaping (ChannelJoinProgress) -> Void
    ) async throws
}

extension SyncEngine: ChannelJoining {}

/// The browser's three tabs — a filter over one array, exactly as Desktop's
/// `BrowserTab` is (`ChannelBrowserDialog.tsx`).
enum BrowseTab: String, CaseIterable, Identifiable {
    case all, joined, archived
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Channels"
        case .joined: "Joined"
        case .archived: "Archived"
        }
    }
}

/// How the list is ordered. Desktop offers Alphabetical / Recent / Most members;
/// Recent is deliberately absent here — ``BrowsableChannel`` carries no activity
/// timestamp, and inventing one from a different query would sort the two clients
/// differently. It can follow when the store exposes it.
enum BrowseSort: String, CaseIterable, Identifiable {
    case alphabetical, members
    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .members: "Most members"
        }
    }
}

/// Drives ``BrowseChannelsView``: the live catalogue, the search/tab/sort derivation,
/// and the join round trip.
///
/// One pattern, shared with ``ChannelListModel``: `DatabaseSignal` re-fires on every
/// relevant commit and each fire re-reads `store.browsableChannels(identity:)` — so the
/// list stays live as the directory pass commits rosters, without a second list to fall
/// out of step.
@MainActor
@Observable
final class BrowseChannelsModel {
    var searchText = ""
    var tab: BrowseTab = .all
    var sort: BrowseSort = .alphabetical

    /// Every channel this identity can see, as the store answers it. Filtering and
    /// ordering are ``visible``'s, per pass, so a tab flip never waits on a query.
    private(set) var channels: [BrowsableChannel] = []
    /// The channel a join is in flight for, or `nil`. One at a time: the Join buttons
    /// disable while one runs, because two concurrent hydrations compete for the same
    /// request budget and the reader is navigating into the first one anyway.
    private(set) var joiningChannelID: String?
    /// How far that join has got, for the button to narrate.
    private(set) var joinProgress: ChannelJoinProgress?
    /// The last refusal, in words, or `nil`. Settable so the alert can clear it.
    var joinFailure: String?

    private let store: BuzzEventStore
    /// The local identity, lowercased hex. `nil` degrades to an empty catalogue —
    /// with no key there is nothing the relay would let it join anyway.
    private let identity: String?
    private let joiner: any ChannelJoining

    init(store: BuzzEventStore, identity: String?, joiner: any ChannelJoining) {
        self.store = store
        self.identity = identity
        self.joiner = joiner
        channels = Self.read(store: store, identity: identity)
    }

    var isJoining: Bool { joiningChannelID != nil }

    /// The rows the current search, tab and sort leave standing.
    ///
    /// Visibility is Desktop's rule (`ChannelBrowserDialog.matchingChannels`): an
    /// archived channel is only yours to see if you are in it, a live one if it is open
    /// or you are in it. DMs never reach this — ``BuzzEventStore/browsableChannels(identity:)``
    /// excludes them at the query.
    var visible: [BrowsableChannel] {
        let query = normalizedQuery
        var rows = channels.filter { channel in
            channel.isArchived ? channel.isJoined : (!channel.isPrivate || channel.isJoined)
        }

        switch tab {
        case .all: rows = rows.filter { !$0.isArchived }
        case .joined: rows = rows.filter { $0.isJoined && !$0.isArchived }
        case .archived: rows = rows.filter { $0.isArchived }
        }

        var scores: [String: Int] = [:]
        if !query.isEmpty {
            rows = rows.filter { channel in
                let score = ChannelSearchScore.score(
                    name: displayName(of: channel),
                    about: channel.about ?? channel.topic,
                    against: query
                )
                if let score { scores[channel.id] = score }
                return score != nil
            }
        }

        // One comparator rather than two passes: Swift's sort is not stable, so ranking
        // by score *after* an alphabetical sort would shuffle equal-score rows. Score
        // first (when searching), then the chosen order, then the id so equal rows have
        // one answer.
        rows.sort { lhs, rhs in
            if !query.isEmpty {
                let left = scores[lhs.id] ?? .max
                let right = scores[rhs.id] ?? .max
                if left != right { return left < right }
            }
            switch sort {
            case .members:
                if lhs.memberCount != rhs.memberCount { return lhs.memberCount > rhs.memberCount }
            case .alphabetical:
                break
            }
            let leftName = displayName(of: lhs).lowercased()
            let rightName = displayName(of: rhs).lowercased()
            if leftName != rightName { return leftName < rightName }
            return lhs.id < rhs.id
        }
        return rows
    }

    /// What a row is called where a name is missing: the channel id, which is at least
    /// stable and searchable, rather than a blank line.
    func displayName(of channel: BrowsableChannel) -> String {
        let name = channel.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? channel.id : name
    }

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Joins one channel, narrating progress, and says whether it is safe to navigate.
    ///
    /// `false` covers both the refusal (put into ``joinFailure`` in words) and a call
    /// made while another join is already running — the buttons disable, but a double
    /// tap can land before the first state assignment paints.
    func join(_ channelID: String) async -> Bool {
        guard joiningChannelID == nil else { return false }
        joiningChannelID = channelID
        joinProgress = .publishing
        joinFailure = nil
        defer {
            joiningChannelID = nil
            joinProgress = nil
        }

        do {
            try await joiner.joinChannel(channelID) { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self, self.joiningChannelID == channelID else { return }
                    self.joinProgress = phase
                }
            }
            return true
        } catch {
            joinFailure = Self.describe(error)
            return false
        }
    }

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`, which
    /// cancels it when the sheet goes away. `nonisolated` so the re-read runs off the
    /// main actor; only the assignment hops back on.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let rows = Self.read(store: store, identity: identity)
                await apply(rows)
            }
        } catch {
            // The stream ends on cancellation or store teardown; the last catalogue
            // remains on screen rather than blanking.
        }
    }

    private func apply(_ rows: [BrowsableChannel]) {
        // The same guard the sidebar's model carries: the observation re-fires on every
        // committed transaction, and an equal assignment still invalidates every view
        // reading it — which here is every visible row.
        guard rows != channels else { return }
        channels = rows
    }

    private nonisolated static func read(store: BuzzEventStore, identity: String?) -> [BrowsableChannel] {
        guard let identity else { return [] }
        return (try? store.browsableChannels(identity: identity)) ?? []
    }

    /// The refusal in words the reader can act on, mirroring how
    /// ``CreateChannelModel`` speaks — the classified reasons first, the transport after.
    private static func describe(_ error: Error) -> String {
        guard let joinError = error as? ChannelJoinError else {
            return "Couldn’t join the channel. Try again."
        }
        switch joinError {
        case .rejected(.restricted):
            return "This channel is private — joining needs an invitation."
        case .rejected(.rateLimited):
            return "The relay is rate-limiting requests. Try again in a moment."
        case let .rejected(.invalid(message)) where !message.isEmpty:
            // The relay's own words — `channel is archived`, `channel not found` —
            // are already the explanation.
            return "The relay refused the join: \(message)."
        case .rejected:
            return "The relay refused the join."
        case .publishFailed:
            return "Couldn’t reach the relay. Check the connection and try again."
        }
    }
}
