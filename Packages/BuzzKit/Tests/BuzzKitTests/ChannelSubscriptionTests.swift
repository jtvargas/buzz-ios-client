@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The standing per-channel content subscriptions and the narrowed global REQ — the
/// live-subscription architecture fix.
///
/// Ground truth (measured against the production relay): the relay scopes a REQ by
/// its filters, and a channel-scoped event never fans out to a `#h`-less global
/// subscription. So channel traffic (kind 9/40002/40003/7/5/9005 and `#h`-tagged
/// typing 20002) rides one standing `#h`-scoped subscription per channel, and the
/// global REQ carries only what a global filter can receive (metadata + presence +
/// the `#p`-scoped membership notifications).
@Suite("Channel content subscriptions and narrowed global REQ", .timeLimit(.minutes(1)))
struct ChannelSubscriptionTests {
    /// The measured live-delivering per-channel shape.
    private static let contentKinds: [EventKind] = [
        .channelMessage, .richMessage, .messageEdit,
        .reaction, .deletion, .groupDeleteEvent, .typing,
    ]

    // MARK: - Filter shapes

    @Test("discovery registers a #h-scoped per-channel content REQ; the global REQ is narrowed")
    func discoveryRegistersPerChannelSubAndNarrowsGlobal() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])
        let row = try build.row("m1", at: 1_700_000_005)
        let page = try WindowResponseBuilder.body([row, try build.headBounds(hasMore: false)])
        await harness.http.enqueue(status: 200, body: page)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [metadata])
        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        // The per-channel content REQ: exactly one filter, the measured kinds, `#h`.
        let channelReq = await awaitChannelContentFilter(on: socket, channel: "room")
        #expect(channelReq.kinds == Self.contentKinds)
        #expect(channelReq.tagQueries["h"] == ["room"])
        #expect(channelReq.since == harness.nowSeconds - 5)

        // The global REQ: a `#h`-less live filter of only presence, a separate
        // profile-metadata filter, plus the membership filter — and none of the channel
        // kinds (the scoping invariant).
        let global = await globalREQFilters(on: socket)
        let content = try #require(globalPresenceFilter(in: global))
        #expect(content.kinds == [.presence])
        #expect(content.tagQueries["h"] == nil)

        // Metadata rides its own filter with no `since`. A profile is written once and
        // then sits there, so the live window that is right for presence matches no
        // profile at all — which is how the client came to show short npubs and initials
        // in place of every name and avatar.
        let profiles = try #require(globalProfileFilter(in: global))
        #expect(profiles.kinds == [.metadata])
        #expect(profiles.since == nil)
        #expect(profiles.tagQueries["h"] == nil)
        let deadKinds: [EventKind] = [
            .channelMessage, .reaction, .deletion, .groupDeleteEvent, .richMessage, .messageEdit, .typing
        ]
        for dead in deadKinds {
            #expect(content.kinds?.contains(dead) == false)
        }
        let membership = try #require(membershipFilter(in: global))
        #expect(membership.tagQueries["p"] == [harness.selfPubkey])

        await harness.engine.stop()
    }

    // MARK: - Set reconciliation on membership

    @Test("membership add opens a channel sub; membership remove closes it")
    func membershipGrowsAndShrinksTheSubSet() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()

        try await bootstrap(harness, socket)
        // Two channels already subscribed (as a prior discovery pass would have done).
        try await harness.engine.subscribeChannelContent("room-keep")
        try await harness.engine.subscribeChannelContent("room-leave")
        let leaveID = await awaitChannelContentREQ(on: socket, channel: "room-leave")

        // A membership notification arrives on the global REQ. It is `#p`-scoped to
        // self, so a 44101 means "you left room-leave" and a 44100 means "you joined
        // room-new". Deliver both, then EOSE so the batch flushes (batch size 2).
        let globalID = await globalREQID(on: socket)
        let removed = try relay.event(
            .memberRemoved, "", tags: [["h", "room-leave"], ["p", harness.selfPubkey]], at: 1_700_000_100
        )
        let added = try relay.event(
            .memberAdded, "", tags: [["h", "room-new"], ["p", harness.selfPubkey]], at: 1_700_000_101
        )
        await socket.enqueue(EngineFrames.event(globalID, removed))
        await socket.enqueue(EngineFrames.event(globalID, added))
        await socket.enqueue(EngineFrames.eose(globalID))

        // Remove dropped the sub (with a CLOSE); add opened one for the new channel.
        await waitUntil { await harness.engine.channelContentSubscriptions["room-leave"] == nil }
        await waitUntil { await sentClose(on: socket, subscriptionID: leaveID) }
        await waitUntil { await harness.engine.channelContentSubscriptions["room-new"] != nil }
        _ = await awaitChannelContentREQ(on: socket, channel: "room-new")
        // The untouched channel is still subscribed.
        #expect(await harness.engine.channelContentSubscriptions["room-keep"] != nil)

        await harness.engine.stop()
    }

    // MARK: - Same-batch membership churn (reconnect replay)

    /// A reconnect replays offline membership changes as one batch. When it carries a
    /// leave then a *later* rejoin for the SAME channel, the net fact is joined, so the
    /// standing sub must survive. The old code collapsed the batch into add/remove sets
    /// and applied removes last, ending unsubscribed — silently live-dead until the next
    /// `.ready`. The fix acts on the most-recent `(created_at, id)` event per channel.
    @Test("same-batch leave-then-rejoin for one channel stays subscribed")
    func sameBatchLeaveThenRejoinStaysSubscribed() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()

        try await bootstrap(harness, socket)
        try await harness.engine.subscribeChannelContent("room")
        #expect(await harness.engine.channelContentSubscriptions["room"] != nil)

        // One ingested batch: leave at t1, rejoin at t2 > t1, same channel. Ingested
        // directly so the assertion is deterministic — the membership handler awaits its
        // subscribe/unsubscribe, so the set is settled the moment ingest returns.
        let leave = try relay.event(
            .memberRemoved, "", tags: [["h", "room"], ["p", harness.selfPubkey]], at: 1_700_000_100
        )
        let rejoin = try relay.event(
            .memberAdded, "", tags: [["h", "room"], ["p", harness.selfPubkey]], at: 1_700_000_101
        )
        await harness.engine.ingest(batch: [leave, rejoin], subscription: SubscriptionID("global"), phase: .live)

        // Net fact is the rejoin → still subscribed.
        #expect(await harness.engine.channelContentSubscriptions["room"] != nil)

        await harness.engine.stop()
    }

    /// The mirror: a rejoin then a *later* leave for the same channel nets to left, so
    /// the sub is dropped. Confirms the most-recent-fact rule in the removing direction.
    @Test("same-batch rejoin-then-leave for one channel ends unsubscribed")
    func sameBatchRejoinThenLeaveEndsUnsubscribed() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()

        try await bootstrap(harness, socket)
        try await harness.engine.subscribeChannelContent("room")
        #expect(await harness.engine.channelContentSubscriptions["room"] != nil)

        let rejoin = try relay.event(
            .memberAdded, "", tags: [["h", "room"], ["p", harness.selfPubkey]], at: 1_700_000_100
        )
        let leave = try relay.event(
            .memberRemoved, "", tags: [["h", "room"], ["p", harness.selfPubkey]], at: 1_700_000_101
        )
        await harness.engine.ingest(batch: [rejoin, leave], subscription: SubscriptionID("global"), phase: .live)

        // Net fact is the leave → unsubscribed.
        #expect(await harness.engine.channelContentSubscriptions["room"] == nil)

        await harness.engine.stop()
    }

    // MARK: - Relay CLOSE

    @Test("a relay CLOSE of a channel sub drops it from the set")
    func relayCloseDropsChannelSub() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)
        try await harness.engine.subscribeChannelContent("room")
        let subID = await awaitChannelContentREQ(on: socket, channel: "room")
        #expect(await harness.engine.channelContentSubscriptions["room"] != nil)

        // The relay refuses the subscription (e.g. not a member): a terminal CLOSED.
        await socket.enqueue(EngineFrames.closed(subID, "restricted: not a member"))

        await waitUntil { await harness.engine.channelContentSubscriptions["room"] == nil }

        await harness.engine.stop()
    }

    // MARK: - Harness

    private func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// The filters of the global REQ (the one carrying the membership filter).
    private func globalREQFilters(on relay: ScriptedRelay) async -> [Filter] {
        while true {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame), membershipFilter(in: request.filters) != nil {
                    return request.filters
                }
            }
            await Task.yield()
        }
    }

    /// The subscription id of the global REQ.
    private func globalREQID(on relay: ScriptedRelay) async -> String {
        await awaitREQ(on: relay) { membershipFilter(in: $0) != nil }
    }

    private func sentClose(on relay: ScriptedRelay, subscriptionID: String) async -> Bool {
        for frame in await relay.frames() where closeSubID(frame) == subscriptionID {
            return true
        }
        return false
    }
}

private func closeSubID(_ frame: String) -> String? {
    guard case let .close(id) = try? JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8)) else {
        return nil
    }
    return id
}
