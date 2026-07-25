@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("SyncEngine backfill and live replay lose nothing", .timeLimit(.minutes(1)))
struct SyncEngineBackfillTests {
    // MARK: - T1

    /// T1 — dropped mid-backfill, no loss. The socket delivers e10…e6 of ten stored
    /// events newest-first, then fails before EOSE. On reconnect the re-REQ must
    /// carry the *original* filter (the replay cursor is unarmed until an EOSE), the
    /// relay replays all ten + EOSE, and the store holds all ten exactly once.
    @Test("Re-REQs the original filter and stores all ten exactly once")
    func killMidBackfill() async throws {
        let socket1 = ScriptedRelay()
        let socket2 = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket1, socket2], batchSize: 2
        )

        let fixtures = try EngineFixtures()
        let events = try (1 ... 10).map { index in
            try fixtures.message("m\(index)", in: "room", at: 1_700_000_000 + Int64(index))
        }
        let newestFirst = Array(events.reversed()) // e10 … e1

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket1)
        await answerDiscovery(on: socket1)
        // Channel messages now ride the standing per-channel content sub (the global
        // REQ is `#h`-less and never receives them). Open "room"'s sub explicitly so
        // this replay-cursor test has the standing sub it exercises.
        await harness.engine.subscribeChannelContent("room")

        // e10…e6 as backfill, no EOSE. batchSize 2 flushes e10,e9 and e8,e7; e6 stays
        // buffered and is discarded when the reconnect resets the subscription.
        let sub1 = await awaitChannelContentREQ(on: socket1, channel: "room")
        for event in newestFirst.prefix(5) {
            await socket1.enqueue(EngineFrames.event(sub1, event))
        }
        await waitUntil { (try? await harness.store.count(kind: .channelMessage)) == 4 }
        await socket1.enqueueFailure(.connectionClosed)

        // Reconnect and re-auth on the second socket. The manager re-arms the standing
        // "room" sub onto the fresh socket.
        try await driveAuth(harness.connection, socket2)

        // The re-REQ carries the original content filter — since = now − 5, never
        // shifted to a replay cursor, because no EOSE ever armed one.
        let replayFilter = await awaitChannelContentFilter(on: socket2, channel: "room")
        #expect(replayFilter.since == harness.nowSeconds - 5)
        #expect(replayFilter.until == nil)

        await answerDiscovery(on: socket2)
        let sub2 = await awaitChannelContentREQ(on: socket2, channel: "room")
        for event in newestFirst {
            await socket2.enqueue(EngineFrames.event(sub2, event))
        }
        await socket2.enqueue(EngineFrames.eose(sub2))

        await waitUntil { (try? await harness.store.count(kind: .channelMessage)) == 10 }
        #expect(try await harness.store.count(kind: .channelMessage) == 10)
        for event in events {
            #expect(try await harness.store.event(id: event.id) != nil)
        }

        await harness.engine.stop()
    }

    // MARK: - T2

    /// T2 — airplane mode mid-live, no loss or dup. After EOSE the socket delivers
    /// live e1, e2, then fails. On reconnect the replay filter's `since` must be
    /// `lastSeen − 5`; the relay redelivers e2 (overlap) + e3, e4 + EOSE, and the
    /// store holds e1…e4 each exactly once.
    @Test("Replays since lastSeen−5 and dedupes the overlap on reconnect")
    func airplaneMidLive() async throws {
        let socket1 = ScriptedRelay()
        let socket2 = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket1, socket2]
        )

        let fixtures = try EngineFixtures()
        let event1 = try fixtures.message("m1", in: "room", at: 1_700_000_001)
        let event2 = try fixtures.message("m2", in: "room", at: 1_700_000_002)
        let event3 = try fixtures.message("m3", in: "room", at: 1_700_000_003)
        let event4 = try fixtures.message("m4", in: "room", at: 1_700_000_004)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket1)
        await answerDiscovery(on: socket1)
        await harness.engine.subscribeChannelContent("room")

        let sub1 = await awaitChannelContentREQ(on: socket1, channel: "room")
        await socket1.enqueue(EngineFrames.eose(sub1)) // caught up → live
        await socket1.enqueue(EngineFrames.event(sub1, event1))
        await socket1.enqueue(EngineFrames.event(sub1, event2))
        await waitUntil { (try? await harness.store.count(kind: .channelMessage)) == 2 }

        await socket1.enqueueFailure(.connectionClosed) // airplane mode

        try await driveAuth(harness.connection, socket2)
        let replayFilter = await awaitChannelContentFilter(on: socket2, channel: "room")
        #expect(replayFilter.since == event2.createdAt - 5)

        await answerDiscovery(on: socket2)
        let sub2 = await awaitChannelContentREQ(on: socket2, channel: "room")
        await socket2.enqueue(EngineFrames.event(sub2, event2)) // overlap
        await socket2.enqueue(EngineFrames.event(sub2, event3))
        await socket2.enqueue(EngineFrames.event(sub2, event4))
        await socket2.enqueue(EngineFrames.eose(sub2))

        await waitUntil { (try? await harness.store.count(kind: .channelMessage)) == 4 }
        #expect(try await harness.store.count(kind: .channelMessage) == 4)
        for event in [event1, event2, event3, event4] {
            #expect(try await harness.store.event(id: event.id) != nil)
        }

        await harness.engine.stop()
    }
}
