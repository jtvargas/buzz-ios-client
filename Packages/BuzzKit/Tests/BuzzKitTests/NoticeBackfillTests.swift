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
/// # Why it cannot ride the window
///
/// The obvious fix — add `.systemMessage` to the window request's kinds — looks right
/// and does nothing. The relay stores a notice with `insert_event`, not
/// `insert_event_with_thread_metadata`, so it has no `thread_metadata` row, and a
/// channel window page is computed *from* that table. Hence a separate one-shot.
@Suite("Relay notices are backfilled", .timeLimit(.minutes(1)))
struct NoticeBackfillTests {
    /// The notice backfill query: `kinds == [.systemMessage]`, `#h`-scoped.
    private func isNoticeREQ(_ filters: [Filter], channel: String) -> Bool {
        filters.contains { $0.kinds == [.systemMessage] && $0.tagQueries["h"] == [channel] }
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
