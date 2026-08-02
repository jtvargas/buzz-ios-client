import Foundation
import NostrCore

public protocol ChannelDirectoryFetching: Sendable {
    func fetch(
        selfPubkey: String,
        previouslyActiveChannels: Set<String>
    ) async throws -> ChannelDirectorySnapshot
}

/// A concrete boundary around any directory fetcher.
///
/// ``SyncEngine`` accepts this concrete value rather than putting an existential
/// or opaque generic directly in an actor initializer. The underlying fetcher is
/// still injected and retained behind the engine's reference context, while the
/// stable initializer shape avoids Swift's actor-initializer code-generation
/// failure for the legacy no-directory overload.
public struct AnyChannelDirectoryFetcher: ChannelDirectoryFetching, Sendable {
    private let fetchValue: @Sendable (String, Set<String>) async throws -> ChannelDirectorySnapshot

    public init<Fetcher: ChannelDirectoryFetching>(_ fetcher: Fetcher) {
        fetchValue = { selfPubkey, previouslyActiveChannels in
            try await fetcher.fetch(
                selfPubkey: selfPubkey,
                previouslyActiveChannels: previouslyActiveChannels
            )
        }
    }

    public func fetch(
        selfPubkey: String,
        previouslyActiveChannels: Set<String>
    ) async throws -> ChannelDirectorySnapshot {
        try await fetchValue(selfPubkey, previouslyActiveChannels)
    }
}

public enum ChannelDirectoryError: Error, Equatable {
    case transport(TransportError)
    case httpStatus(Int)
    case unreadableResponse
    case invalidPagination
}

/// Authenticated, composite-cursor traversal of the relay's channel directory.
///
/// Every query is completed before a snapshot is returned. The caller therefore
/// has only two outcomes: a complete value safe to commit atomically, or an error
/// that leaves the prior store state untouched.
public struct ChannelDirectoryClient: ChannelDirectoryFetching, Sendable {
    public static let pageSize = 500
    /// How many channels one state request asks about.
    ///
    /// **This has to stay below a third of ``pageSize``.** That request names three kinds
    /// (39000, 39001, 39002) under one `limit`, so it can return `3 × channelBatchSize`
    /// rows — and the relay clamps and then truncates a single `limit` in
    /// `created_at DESC` order (`buzz/crates/buzz-db/src/event.rs:346` and `:531`). Past
    /// that ratio the answer silently loses the least-recently-updated channels' state,
    /// and a channel with no metadata row reads as one that no longer exists. At 100 the
    /// worst case is 300 of 500, and the pagination below never even engages.
    public static let channelBatchSize = 100

    private let transport: any HTTPTransport
    private let queryURL: URL
    private let signer: any EventSigner
    /// Read once per fetch, and only to decide whether an ephemeral channel's deadline has
    /// passed. Injected so that rule is testable without waiting out a real TTL.
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport,
        queryURL: URL,
        signer: some EventSigner,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.queryURL = queryURL
        self.signer = signer
        self.now = now
    }

    public func fetch(
        selfPubkey: String,
        previouslyActiveChannels: Set<String>
    ) async throws -> ChannelDirectorySnapshot {
        try Task.checkCancellation()

        let hidden = try await fetchHiddenDirectMessages(viewer: selfPubkey)
        let membershipPages = try await fetchAll(
            DirectoryFilter(
                kinds: [.groupMembers],
                tagQueries: ["p": [selfPubkey]]
            )
        )
        let currentMembership = Self.latestReplaceables(in: membershipPages)
        let currentChannels: Set<String> = Set(
            currentMembership.compactMap { event in
                guard event.kind == EventKind.groupMembers,
                      Self.roster(event, contains: selfPubkey)
                else { return nil }
                return event.addressableIdentifier
            }
        )

        // Everything the relay is willing to show this key, whether or not a roster
        // names them. `POST /query` scopes channel-scoped events to
        // `get_accessible_channel_ids`, which is the viewer's memberships **UNION every
        // channel with `visibility = 'open'`** (`buzz-db/src/channel.rs:746-761`,
        // enforced at `buzz-relay/src/api/bridge.rs:1005`). Asking only "whose roster
        // contains me?" — the query above — therefore cannot see an open channel the
        // viewer has not joined, which is every channel in a community they have just
        // been invited to. That is the difference between a sidebar and a blank panel
        // on a first join.
        //
        // Ephemeral channels whose deadline has passed are **not** discoverable, even
        // though the relay still serves them. See ``hasOutlivedItsDeadline(_:now:)``: the
        // relay never deletes a channel row, so an expired one is open and answerable for
        // ever, and discovery is the one route by which somebody who never joined it can
        // be shown it. A viewer's own memberships are left alone — leaving a channel is
        // theirs to do, not this client's.
        let discoveryPages = try await fetchAll(DirectoryFilter(kinds: [.groupMetadata], tagQueries: [:]))
        let asOf = now()
        let discoverableChannels = Set(
            discoveryPages
                .filter { !Self.hasOutlivedItsDeadline($0, now: asOf) }
                .compactMap(\.addressableIdentifier)
        )

        let relevantChannels = currentChannels
            .union(previouslyActiveChannels)
            .union(discoverableChannels)
        var stateEvents: [NostrEvent] = []
        let ordered = relevantChannels.sorted()
        for start in stride(from: 0, to: ordered.count, by: Self.channelBatchSize) {
            try Task.checkCancellation()
            let end = min(start + Self.channelBatchSize, ordered.count)
            stateEvents += try await fetchAll(
                DirectoryFilter(
                    kinds: [.groupMetadata, .groupAdmins, .groupMembers],
                    tagQueries: ["d": Array(ordered[start ..< end])]
                )
            )
        }

        let events = Self.latestReplaceables(in: membershipPages + discoveryPages + stateEvents)
        var states = Self.accessStates(
            for: relevantChannels,
            from: events,
            viewer: selfPubkey,
            now: asOf
        )

        // A hide is not a membership change, so every hidden DM has just been resolved
        // to `.active` above — correctly, since that is what the roster says. The
        // viewer's own visibility snapshot is the only thing that knows better.
        //
        // It only ever demotes an already-`.active` channel: one that is archived,
        // gone, or no longer yours is off the sidebar for a stronger reason already,
        // and calling it merely hidden would replace a real explanation with a weaker
        // one. Nothing here re-checks that the id names a DM — the relay refuses a hide
        // for anything else (`handle_dm_hide` requires `channel_type == "dm"`), and it
        // is the same relay whose roster decided membership one block above, so a
        // second opinion from this side would be theatre.
        for channelID in hidden where states[channelID] == .active {
            states[channelID] = .hidden
        }

        return ChannelDirectorySnapshot(events: events, states: states)
    }

    /// Reads each channel's relay-signed state into the viewer's access to it.
    ///
    /// `now` is here for one reason: an expired ephemeral channel has to lose its access
    /// row, not merely fail to gain one. Filtering discovery only protects a device that
    /// has never seen the channel. Any device that has already cached one as `.active`
    /// feeds it back in through `previouslyActiveChannels`, and this is the only place
    /// that can retire it. See the `isOpen` branch below.
    static func accessStates(
        for channels: Set<String>,
        from events: [NostrEvent],
        viewer: String,
        now: Date
    ) -> [String: ChannelAccessState] {
        let byChannel = Dictionary(grouping: events) { $0.addressableIdentifier ?? "" }
        var states: [String: ChannelAccessState] = [:]
        for channelID in channels {
            let channelEvents = byChannel[channelID] ?? []
            let roster: NostrEvent? = channelEvents.first {
                $0.kind == EventKind.groupMembers
            }
            let metadata: NostrEvent? = channelEvents.first {
                $0.kind == EventKind.groupMetadata
            }
            let isMember = roster.map { Self.roster($0, contains: viewer) } ?? false
            let isArchived = metadata.map(Self.isArchived) ?? false
            let isOpen = metadata.map(Self.isOpen) ?? false
            let hasExpired = metadata.map { Self.hasOutlivedItsDeadline($0, now: now) } ?? false

            if isMember {
                states[channelID] = metadata == nil ? .unavailable : (isArchived ? .archived : .active)
            } else if isArchived {
                states[channelID] = .archived
            } else if isOpen, !hasExpired {
                // Not on the roster, but the relay treats an open channel as fully the
                // viewer's: it serves the history and *accepts their writes* — membership
                // is checked first, open visibility is the accepted fallback
                // (`buzz-relay/src/handlers/ingest.rs:531-545`). So `.active` is the
                // honest state, not a generous one, and `.notMember` would take a
                // conversation read-only that the relay would happily accept a message
                // into.
                //
                // Unless its deadline has passed, and this is the only rung that can undo
                // that. Discovery declining to *offer* an expired channel does nothing for
                // a device that already holds an `.active` row for one: that row comes
                // back every pass as `previouslyActiveChannels`, lands here, reads as open,
                // and is written back active — for ever. Falling through to `.notMember`
                // below is what actually retires it, and it is the truthful answer anyway:
                // the roster does not name this viewer.
                states[channelID] = .active
            } else if roster != nil {
                states[channelID] = .notMember
            } else {
                // Absence cannot distinguish deletion from an authorization loss.
                states[channelID] = .unavailable
            }
        }
        return states
    }

    /// The channel ids in the viewer's own NIP-DV visibility snapshot — the DMs they
    /// currently have hidden.
    ///
    /// # Why a relay that will not answer this must not cost you your sidebar
    ///
    /// This rides the same authenticated endpoint as the membership query, so the
    /// obvious shape — let it throw like everything else — would hand a relay that
    /// does not implement NIP-DV the power to fail the entire directory pass, and the
    /// app would sit on `Can't reach the relay` against a relay it is talking to
    /// perfectly well. That is a far worse failure than the one this fetch exists to
    /// fix, so the two error classes are separated:
    ///
    /// - **The relay answered, and its answer was a refusal or unreadable.** Nothing
    ///   about retrying changes that, and NIP-DV §Client Behavior already defines the
    ///   fallback: no snapshot means nothing is hidden. Absorbed, and the rest of the
    ///   pass proceeds normally.
    /// - **The relay did not answer at all** (transport, cancellation). The membership
    ///   query is about to hit the same wall, so this propagates and the caller keeps
    ///   its last good state — which still has the hidden DMs hidden. Preserving the
    ///   previous answer is the only way a network blip cannot flash a hidden DM back
    ///   onto the sidebar.
    private func fetchHiddenDirectMessages(viewer: String) async throws -> Set<String> {
        let page: [NostrEvent]
        do {
            page = try await fetchPage(
                DirectoryFilter(
                    kinds: [.dmVisibility],
                    tagQueries: ["p": [viewer]],
                    limit: 1
                )
            )
        } catch ChannelDirectoryError.httpStatus, ChannelDirectoryError.unreadableResponse {
            return []
        }

        // Addressable and keyed by `d`, so the newest snapshot is the complete hidden
        // set. The relay orders `created_at DESC` under a limit, but choosing the
        // newest here rather than trusting position also refuses a snapshot addressed
        // to somebody else — the tag that authorises the read is `p`, and only `d`
        // says whose set this is.
        guard let snapshot = page
            .filter({ event in
                event.kind == EventKind.dmVisibility
                    && event.addressableIdentifier?.caseInsensitiveCompare(viewer) == .orderedSame
            })
            .max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) })
        else { return [] }

        return Set(snapshot.tags.compactMap { tag in
            guard tag.count > 1, tag[0] == "h", !tag[1].isEmpty else { return nil }
            return tag[1]
        })
    }

    private func fetchAll(_ base: DirectoryFilter) async throws -> [NostrEvent] {
        var cursor: DirectoryCursor?
        var priorCursor: DirectoryCursor?
        var result: [NostrEvent] = []

        while true {
            try Task.checkCancellation()
            var filter = base
            filter.limit = Self.pageSize
            filter.cursor = cursor
            let page = try await fetchPage(filter)
            result += page
            guard page.count == Self.pageSize else { return result }

            let next = try Self.paginationCursor(for: page)
            guard next != priorCursor else {
                throw ChannelDirectoryError.invalidPagination
            }
            priorCursor = next
            cursor = next
        }
    }

    static func paginationCursor(for page: [NostrEvent]) throws -> DirectoryCursor {
        guard let oldest = page.min(by: {
            ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }) else {
            throw ChannelDirectoryError.invalidPagination
        }
        return DirectoryCursor(createdAt: oldest.createdAt, id: oldest.id)
    }

    private func fetchPage(_ filter: DirectoryFilter) async throws -> [NostrEvent] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode([filter])
        let authorization = try await NIP98.authorizationHeader(
            url: queryURL,
            method: "POST",
            body: body,
            signer: signer
        )

        let response: (body: Data, status: Int)
        do {
            response = try await transport.post(
                body: body,
                to: queryURL,
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": authorization,
                ]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransportError {
            throw ChannelDirectoryError.transport(error)
        }

        try Task.checkCancellation()
        guard (200 ... 299).contains(response.status) else {
            throw ChannelDirectoryError.httpStatus(response.status)
        }
        guard let events = try? JSONDecoder().decode([NostrEvent].self, from: response.body) else {
            throw ChannelDirectoryError.unreadableResponse
        }
        return events
    }

    /// Collapses addressable group state by `(kind, d)`, choosing the greatest
    /// `(created_at, event_id)` cursor so delivery order cannot affect the result.
    static func latestReplaceables(in events: [NostrEvent]) -> [NostrEvent] {
        var latest: [String: NostrEvent] = [:]
        for event in events {
            guard let identifier = event.addressableIdentifier else { continue }
            let key = "\(event.kind.rawValue):\(identifier)"
            if let existing = latest[key],
               (event.createdAt, event.id) <= (existing.createdAt, existing.id) {
                continue
            }
            latest[key] = event
        }
        return latest.values.sorted {
            ($0.createdAt, $0.id) > ($1.createdAt, $1.id)
        }
    }

    private static func roster(_ event: NostrEvent, contains pubkey: String) -> Bool {
        event.tags.contains { tag in
            guard tag.count > 1, tag[0] == "p" else { return false }
            return tag[1].caseInsensitiveCompare(pubkey) == .orderedSame
        }
    }

    /// Whether the relay called this channel open, from its own tag on kind:39000.
    ///
    /// The relay stamps exactly one of `public` / `private` from the same `visibility`
    /// column the access query reads (`side_effects.rs:1064-1071`). Read *positively* —
    /// a metadata event predating the tag would otherwise turn every private channel
    /// the viewer has left into one they can walk back into. Not to be confused with
    /// `closed`, which every channel carries: that is NIP-29 for "joining takes an
    /// explicit act", not "you may not look".
    private static func isOpen(_ event: NostrEvent) -> Bool {
        event.tags.contains { tag in
            guard let name = tag.first else { return false }
            return name.lowercased() == "public"
        }
    }

    /// Whether this channel was given a life and has outlived it.
    ///
    /// # Why a client has to decide this at all
    ///
    /// Because it cannot assume the relay already has. A Buzz relay records `ttl_seconds`
    /// and a `ttl_deadline` on an ephemeral channel and publishes both on its kind-39000
    /// (`buzz-relay/src/handlers/side_effects.rs:1101-1107`, *"clients use this to show
    /// countdown timers"*). Expiry is meant to be handled server-side by a reaper that
    /// archives the row every 60 seconds (`buzz-db/src/channel.rs:1495`, run from
    /// `buzz-relay/src/main.rs:643`) — it archives rather than deletes, which is why there
    /// is no `DELETE FROM channels` in the relay to find.
    ///
    /// But *meant to* is not *has*. `homelab.tail4bc643.ts.net` is carrying eight
    /// unarchived expired channels — `livesub-*` and `buzzkit-p2-*`, created by this
    /// package's own live suite (`LivePiSupport.swift:165`, `ttlSeconds: 300`) — each
    /// owned by a throwaway key, each with one member who is not the viewer, each eleven
    /// days past a five-minute deadline, and each still served to everybody on that relay.
    /// They were made on 22 July, one day before the reaper landed, and that relay has not
    /// swept them since. A client that trusts the archived flag alone shows all eight.
    ///
    /// Read from the deadline the relay publishes rather than from the name, because the
    /// names are an accident of which fixtures happened to leak; a client that hid
    /// `livesub-*` would be hiding this week's debris and none of next week's.
    ///
    /// Absent or unparseable means *not expired*. A channel with no deadline is an
    /// ordinary one, and a deadline this client cannot read is not grounds for hiding a
    /// conversation.
    static func hasOutlivedItsDeadline(_ event: NostrEvent, now: Date) -> Bool {
        guard let tag = event.tags.first(where: { $0.first?.lowercased() == "ttl_deadline" }),
              tag.count > 1,
              let deadline = Self.rfc3339(tag[1])
        else { return false }
        return deadline < now
    }

    /// The relay writes these with `chrono`'s `to_rfc3339`, which carries fractional
    /// seconds; `ISO8601DateFormatter` needs to be told that, and told separately not to
    /// expect them. Both are tried rather than assuming the shape of somebody else's clock.
    private static func rfc3339(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func isArchived(_ event: NostrEvent) -> Bool {
        event.tags.contains { tag in
            guard tag.count > 1 else { return false }
            return tag[0].lowercased() == "archived"
                && tag[1].lowercased() == "true"
        }
    }
}

struct DirectoryCursor: Encodable, Equatable {
    let createdAt: Int64
    let id: String
}

struct DirectoryFilter: Encodable {
    var kinds: [EventKind]
    var tagQueries: [String: [String]]
    var limit = ChannelDirectoryClient.pageSize
    var cursor: DirectoryCursor?

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(kinds.map(\.rawValue), forKey: Key("kinds"))
        try container.encode(limit, forKey: Key("limit"))
        for (name, values) in tagQueries {
            try container.encode(values, forKey: Key("#\(name)"))
        }
        if let cursor {
            try container.encode(cursor.createdAt, forKey: Key("until"))
            try container.encode(cursor.id, forKey: Key("before_id"))
        }
    }
}
