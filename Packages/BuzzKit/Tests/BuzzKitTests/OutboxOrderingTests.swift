@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The outbox drains in enqueue order (SQLite `rowid`), one at a time, so a reaction
/// lifecycle that travels through it serializes on the wire in the order it was
/// enqueued — even when every send shares one `created_at` second.
///
/// This matters for the relay's reaction dedup: the relay dedups reactions on
/// `(target, actor, emoji)` before fan-out, so a re-react after a withdrawal only
/// clears — and re-delivers — if the withdrawal (kind 5) reaches the relay *before*
/// the re-react (kind 7). If the drain reordered them, the re-react would land while
/// the dedup row still stood; the relay would answer `duplicate:` (which the client
/// maps to success and writes into its local log) and the withdrawal would then delete
/// the original relay-side, leaving this one device showing a reaction no other device
/// has.
///
/// The clock here is **frozen**, so all three sends tie on `created_at` — the exact
/// same-second condition under which the old `ORDER BY created_at, event_id` drain went
/// nondeterministic. `reReact` is minted so its id sorts *before* the withdrawal's, so
/// the old event-id tiebreak would deterministically publish it first (wrong); the
/// `rowid` order keeps enqueue order.
@Suite("Outbox serializes a reaction lifecycle", .timeLimit(.minutes(1)))
struct OutboxOrderingTests {
    @Test("react → withdraw → re-react drain in enqueue order under a frozen clock; withdrawal lands first")
    func reactionLifecycleSerializes() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        // Frozen: every enqueue stamps the same created_at second — the tie the old
        // ordering could not break deterministically.
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket],
            storeClock: { frozen }
        )
        let target = "aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee"

        let react = try await harness.store.enqueue(
            kind: .reaction, content: "👍", in: "room", tags: [["e", target]], with: harness.signer
        )
        let withdraw = try await harness.store.enqueue(
            kind: .deletion, content: "", in: "room", tags: [["e", react.event.id]], with: harness.signer
        )
        // Mint a re-react whose id sorts BEFORE the withdrawal's, so the old
        // `event_id ASC` tiebreak would place it ahead of the withdrawal — the bug. It
        // always carries a `nonce` tag so it never hashes to `react`'s id (identical
        // kind/content/tags/created_at would collide under the frozen clock); the nonce
        // also varies the id without changing the (target, actor, emoji) dedup tuple.
        // Losers are discarded so only the winner stays queued (last → highest rowid).
        var nonce = 0
        var reReact = try await harness.store.enqueue(
            kind: .reaction, content: "👍", in: "room",
            tags: [["e", target], ["nonce", String(nonce)]], with: harness.signer
        )
        while reReact.event.id >= withdraw.event.id {
            try await harness.store.discard(reReact.event.id)
            nonce += 1
            reReact = try await harness.store.enqueue(
                kind: .reaction, content: "👍", in: "room",
                tags: [["e", target], ["nonce", String(nonce)]], with: harness.signer
            )
        }

        // Preconditions: the same-second tie, and the id inversion the old order trips on.
        #expect(react.event.createdAt == withdraw.event.createdAt)
        #expect(withdraw.event.createdAt == reReact.event.createdAt)
        #expect(reReact.event.id < withdraw.event.id)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)

        // Drive the drain, answering each publish's OK as it appears, and read back the
        // wire order. The order is exactly the enqueue order, and the withdrawal
        // precedes the re-react so the relay's dedup row clears before it arrives.
        let ids = [react.event.id, withdraw.event.id, reReact.event.id]
        let published = await drainAndCollectWireOrder(ids, on: socket)
        #expect(published == ids)
        let withdrawIndex = try #require(published.firstIndex(of: withdraw.event.id))
        let reReactIndex = try #require(published.firstIndex(of: reReact.event.id))
        #expect(withdrawIndex < reReactIndex)

        await harness.engine.stop()
    }

    /// Drives the on-ready drain by answering each publish's OK as it appears — in
    /// whatever order the drain chose, so the test never depends on the order it is
    /// measuring nor deadlocks on a wrongly-ordered (old) drain — and returns the ids
    /// published, in wire order. Bounded so a regression fails the equality check fast
    /// rather than hanging the suite.
    private func drainAndCollectWireOrder(_ ids: [String], on socket: ScriptedRelay) async -> [String] {
        var acked: Set<String> = []
        var spins = 0
        while acked.count < ids.count, spins < 50_000 {
            for id in await socket.frames().compactMap(publishedEventID)
                where ids.contains(id) && !acked.contains(id) {
                await socket.enqueue(EngineFrames.ok(id, true))
                acked.insert(id)
            }
            spins += 1
            await Task.yield()
        }
        return await socket.frames().compactMap(publishedEventID)
    }
}
