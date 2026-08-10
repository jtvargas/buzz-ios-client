@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// A channel's relay notices reach a device that was not watching when they happened.
///
/// # The defect this exists for
///
/// Reported 2026-08-01: a member added days earlier rendered on the Flutter client and
/// was **absent** in Hive — not drawn badly, absent. The event had never been fetched.
///
/// A kind-40099 notice reached a client by exactly one route, the live channel
/// subscription, whose `since` reaches back ``SyncEngineConfig/liveSinceWindow`` — five
/// seconds. Both history paths ask the relay for `kinds: [.channelMessage]` and nothing
/// else. So a notice was visible only to a client subscribed to that channel in the
/// moment it happened, and invisible for ever afterwards.
///
/// # Why the window is not enough
///
/// The relay stores a notice with `insert_event`, not
/// `insert_event_with_thread_metadata`, so it has no `thread_metadata` row. A window page
/// does return one — `get_channel_window_on` left-joins that table and admits
/// `tm.depth IS NULL` (`buzz-db/src/thread.rs`) — but only where a window is *asked for*,
/// and the reconcile pass that closes the gap between the head and the watermark asks for
/// `kind:9` alone. Widening that filter would deepen scroll-back and still leave the
/// launch pass blind. Hence a separate one-shot, with no floor under it.
///
/// Kinds 48100/48103 — a huddle starting and ending — are stored the same way and were
/// absent for the same reason, reported 2026-08-10. They ride this fetch as a second
/// filter.
@Suite("Relay notices are backfilled", .timeLimit(.minutes(1)))
struct NoticeBackfillTests {
    /// The notice backfill query: `kinds == [.systemMessage]`, `#h`-scoped.
    private func isNoticeREQ(_ filters: [Filter], channel: String) -> Bool {
        filters.contains { $0.kinds == [.systemMessage] && $0.tagQueries["h"] == [channel] }
    }

    /// The huddle half of the same REQ. It rides *beside* the notice filter rather than
    /// merged into it, so each keeps its own `limit` at the relay — a channel with a long
    /// joining history would otherwise spend the whole budget on notices and return no
    /// huddle at all, silently.
    private func huddleFilter(in filters: [Filter], channel: String) -> Filter? {
        filters.first { $0.kinds == [.huddleStarted, .huddleEnded] && $0.tagQueries["h"] == [channel] }
    }

    /// A client-signed `48100`, as the desktop client publishes one: `h`-tagged to the
    /// channel the huddle was started *from*, its body naming the huddle's own channel.
    /// Signed by the peer rather than the relay — unlike a notice, this kind is gated on
    /// `ChannelsWrite` and carries its actor in its own `pubkey`.
    private func huddleStart(_ fixtures: EngineFixtures, in channel: String, at seconds: Int64) throws -> NostrEvent {
        try fixtures.peer.event(
            .huddleStarted,
            "{\"ephemeral_channel_id\":\"9f1c0f3a-0000-4000-8000-00000000abcd\"}",
            tags: [["h", channel]],
            at: seconds
        )
    }

    /// A relay-signed `member_joined`, as `emit_system_message` builds one.
    private func notice(_ fixtures: EngineFixtures, in channel: String, at seconds: Int64) throws -> NostrEvent {
        let actor = String(repeating: "a", count: 64)
        let target = String(repeating: "b", count: 64)
        return try fixtures.relay.event(
            .systemMessage,
            "{\"type\":\"member_joined\",\"actor\":\"\(actor)\",\"target\":\"\(target)\"}",
            tags: [["h", channel]],
            at: seconds
        )
    }

    /// Spins for a *bounded* time waiting for the notice REQ, returning `nil` if it
    /// never comes.
    ///
    /// Deliberately not the shared unbounded `awaitREQ`: with the backfill removed this
    /// test is supposed to go **red**, and an unbounded spin makes it hang instead —
    /// which reads as a stuck CI job rather than as a regression. Verified by disabling
    /// `assembleNotices` and watching this fail with the message below.
    private func awaitNoticeREQ(on relay: ScriptedRelay, channel: String) async -> String? {
        for _ in 0 ..< 2000 {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame), isNoticeREQ(request.filters, channel: channel) {
                    return request.id
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test("A notice older than the live window lands in the timeline it belongs to")
    func backfillsANoticeTheLiveWindowCouldNotReach() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let fixtures = try EngineFixtures()

        // A healthy window page, so the reconcile takes the normal path rather than the
        // degradation fallback — the notice fetch must happen on *that* path too.
        let build = try WindowResponseBuilder(channel: "room")
        let head = try build.row("m1", at: 1_700_000_100)
        await harness.http.enqueue(
            status: 200,
            body: try WindowResponseBuilder.body([head, try build.headBounds(hasMore: false)])
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [try fixtures.metadata(for: "room", name: "Room")])

        // Days older than anything the 5-second live filter could have carried.
        let old = try notice(fixtures, in: "room", at: 1_700_000_000)
        let noticeID = try #require(
            await awaitNoticeREQ(on: socket, channel: "room"),
            "the reconcile never asked the relay for this channel's notices"
        )
        await socket.enqueue(EngineFrames.event(noticeID, old))
        await socket.enqueue(EngineFrames.eose(noticeID))

        await waitUntil { (try? await harness.store.event(id: old.id)) != nil }

        // The assertion that matters is the timeline, not the store: a stored event that
        // no read returns is the same defect wearing a different hat.
        let rows = try harness.store.timeline(channel: "room")
        let landed = try #require(rows.first { $0.id == old.id }, "the notice is stored but no timeline row carries it")
        #expect(landed.isNotice)
        #expect(landed.notice == SystemNotice.memberJoined(
            actor: String(repeating: "a", count: 64),
            target: String(repeating: "b", count: 64)
        ))

        await harness.engine.stop()
    }

    /// The same defect in the huddle's shape, reported by the owner 2026-08-10: three
    /// huddles held on the relay, none of them on the phone, because the build that could
    /// read them was installed after they had ended. Kinds 48100/48103 are stored the way
    /// a notice is — no `thread_metadata` row — and ``SyncEngine/reconcileStep`` asks for
    /// `kind:9` alone, so nothing ever *requested* them for a moment this device had not
    /// been awake for.
    @Test("A huddle that started while this device was away lands in the timeline")
    func backfillsAHuddleTheLiveWindowCouldNotReach() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let fixtures = try EngineFixtures()

        let build = try WindowResponseBuilder(channel: "room")
        let head = try build.row("m1", at: 1_700_000_100)
        await harness.http.enqueue(
            status: 200,
            body: try WindowResponseBuilder.body([head, try build.headBounds(hasMore: false)])
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [try fixtures.metadata(for: "room", name: "Room")])

        // Hours older than anything the 5-second live filter could have carried.
        let old = try huddleStart(fixtures, in: "room", at: 1_700_000_000)
        let requestID = try #require(
            await awaitNoticeREQ(on: socket, channel: "room"),
            "the reconcile never asked the relay for this channel's notices"
        )
        await socket.enqueue(EngineFrames.event(requestID, old))
        await socket.enqueue(EngineFrames.eose(requestID))

        await waitUntil { (try? await harness.store.event(id: old.id)) != nil }

        // As with the notice: the store is not the assertion. A huddle event nothing reads
        // back is the same absence the owner reported, one layer down.
        let rows = try harness.store.timeline(channel: "room")
        let landed = try #require(rows.first { $0.id == old.id }, "the huddle is stored but no timeline row carries it")
        #expect(landed.isNotice)
        #expect(landed.notice == SystemNotice.huddleStarted(actor: fixtures.peer.pubkey))

        await harness.engine.stop()
    }

    @Test("The huddle filter rides the notice REQ with its own limit, and no since")
    func theHuddleFilterIsSeparateAndUnbounded() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let fixtures = try EngineFixtures()

        let build = try WindowResponseBuilder(channel: "room")
        await harness.http.enqueue(
            status: 200,
            body: try WindowResponseBuilder.body([try build.headBounds(hasMore: false)])
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [try fixtures.metadata(for: "room", name: "Room")])

        _ = try #require(
            await awaitNoticeREQ(on: socket, channel: "room"),
            "the reconcile never asked the relay for this channel's notices"
        )
        var found: Filter?
        for frame in await socket.frames() {
            if let request = decodeREQ(frame), let filter = huddleFilter(in: request.filters, channel: "room") {
                found = filter
                break
            }
        }
        let filter = try #require(found, "the notice REQ carries no huddle filter")
        #expect(filter.since == nil)
        #expect(filter.limit == SyncEngineConfig.default.noticeBackfillLimit)
        // 48101/48102 — a participant arriving and leaving — are deliberately absent: no
        // surface renders one, and subscribing to an event nothing reads is bandwidth and
        // storage spent to no end.
        #expect(filter.kinds?.contains(48101) == false)
        #expect(filter.kinds?.contains(48102) == false)

        await harness.engine.stop()
    }

    @Test("The backfill asks without a since, because the point is what the live window already missed")
    func theQueryCarriesNoSince() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let fixtures = try EngineFixtures()

        let build = try WindowResponseBuilder(channel: "room")
        await harness.http.enqueue(
            status: 200,
            body: try WindowResponseBuilder.body([try build.headBounds(hasMore: false)])
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [try fixtures.metadata(for: "room", name: "Room")])

        _ = try #require(
            await awaitNoticeREQ(on: socket, channel: "room"),
            "the reconcile never asked the relay for this channel's notices"
        )
        var found: Filter?
        for frame in await socket.frames() {
            if let request = decodeREQ(frame),
               let filter = request.filters.first(where: { $0.kinds == [.systemMessage] }) {
                found = filter
                break
            }
        }
        let filter = try #require(found)
        // A `since` here would reintroduce the whole defect: the notices worth fetching
        // are precisely the ones older than any window this device has been awake for.
        #expect(filter.since == nil)
        #expect(filter.limit == SyncEngineConfig.default.noticeBackfillLimit)

        await harness.engine.stop()
    }
}
