@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The outbox drains oldest-first and one at a time, so a reaction lifecycle that
/// travels through it serializes on the wire in the order it was enqueued.
///
/// This matters for the relay's reaction dedup: the relay dedups reactions on
/// `(target, actor, emoji)` before fan-out, so a re-react after a withdrawal only
/// clears — and re-delivers — if the withdrawal (kind 5) reaches the relay *before*
/// the re-react (kind 7). If the drain reordered them, the re-react would land while
/// the dedup row still stood and be swallowed.
@Suite("Outbox serializes a reaction lifecycle", .timeLimit(.minutes(1)))
struct OutboxOrderingTests {
    /// A monotonic clock so each enqueue gets a strictly increasing `created_at`,
    /// making the drain's `ORDER BY created_at ASC` order deterministic rather than
    /// tie-broken by event id.
    private final class AdvancingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Int64
        init(start: Int64) { seconds = start }
        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            defer { seconds += 1 }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    @Test("react → withdraw → re-react publish in enqueue order; the withdrawal lands before the re-react")
    func reactionLifecycleSerializes() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let clock = AdvancingClock(start: 1_700_000_000)
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket],
            storeClock: { clock.now() }
        )
        let target = "aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee"

        // Queue the three sends while offline, each with a strictly later timestamp:
        // react, then withdraw naming that reaction, then a fresh re-react.
        let react = try await harness.store.enqueue(
            kind: .reaction, content: "👍", in: "room", tags: [["e", target]], with: harness.signer
        )
        let withdraw = try await harness.store.enqueue(
            kind: .deletion, content: "", in: "room", tags: [["e", react.event.id]], with: harness.signer
        )
        let reReact = try await harness.store.enqueue(
            kind: .reaction, content: "👍", in: "room", tags: [["e", target]], with: harness.signer
        )
        #expect(react.event.createdAt < withdraw.event.createdAt)
        #expect(withdraw.event.createdAt < reReact.event.createdAt)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)

        // The on-ready drain sends them oldest-first, awaiting each OK before the next,
        // so answering in order keeps the drain moving.
        for entry in [react, withdraw, reReact] {
            await awaitPublish(on: socket, eventID: entry.event.id)
            await socket.enqueue(EngineFrames.ok(entry.event.id, true))
        }

        await waitUntil { (try? await harness.store.outboxCount()) == 0 }

        // The wire order is exactly the enqueue order — and the withdrawal precedes the
        // re-react, so the relay's dedup row clears before the re-react arrives.
        let published = await publishedEventIDs(on: socket)
        #expect(published == [react.event.id, withdraw.event.id, reReact.event.id])
        let withdrawIndex = try #require(published.firstIndex(of: withdraw.event.id))
        let reReactIndex = try #require(published.firstIndex(of: reReact.event.id))
        #expect(withdrawIndex < reReactIndex)

        await harness.engine.stop()
    }

    /// The event ids of every EVENT publish frame the client sent, in wire order.
    private func publishedEventIDs(on relay: ScriptedRelay) async -> [String] {
        await relay.frames().compactMap(publishedEventID)
    }
}
