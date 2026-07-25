@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

/// The live proof of the fix: a kind-9 published from a *second* connection must
/// arrive at the engine's store via the standing per-channel content subscription —
/// the path that, before this change, never delivered a single live channel event
/// (the engine's only live REQ was `#h`-less and global). Disabled unless
/// `BUZZKIT_INTEGRATION_URL` names the relay, so CI and ordinary `make test` never
/// touch the network.
///
/// Run:
/// `BUZZKIT_INTEGRATION_URL=wss://homelab.tail4bc643.ts.net swift test -c release \
///   --package-path Packages/BuzzKit --filter LivePerChannel`
@Suite(
    "Live per-channel content-sub delivery",
    .enabled(if: LiveRelay.enabled), .serialized, .timeLimit(.minutes(3))
)
struct LivePerChannelDeliveryTests {
    @Test("a kind-9 from a second connection reaches the store via the per-channel sub, under a second")
    func kind9ArrivesUnderASecond() async throws {
        let signer = try InMemorySigner() // creator ⇒ member, so no join flow
        let channel = LiveRelay.channelID()
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        // The "second connection" provisions the channel and later publishes the probe.
        guard let peer = await provision(channel: channel, signer: signer, store: store) else { return }

        let live = LiveEngine(store: store, signer: signer)
        try await live.engine.start()
        guard await poll(timeout: .seconds(30), { await live.engine.state == .running }) else {
            Issue.record("[LIVE] engine never reached running")
            await live.engine.stop(); await peer.stop()
            return
        }
        // The standing per-channel content sub must exist before we publish.
        let registered = await poll(timeout: .seconds(30)) {
            await live.engine.channelContentSubscriptions[channel] != nil
        }
        guard registered else {
            Issue.record("[LIVE] per-channel content sub never registered for \(channel)")
            await live.engine.stop(); await peer.stop()
            return
        }
        print("[LIVE] per-channel content sub registered for \(channel)")
        // Settle so the sub's REQ + EOSE complete and it is live before we measure.
        try await Task.sleep(for: .seconds(2))

        // Publish the probe from the second connection and time its arrival in the store.
        let probe = try await channelMessageEvent(
            "live-sub probe \(UUID().uuidString.prefix(8))", channel: channel, signer: signer
        )
        let clock = ContinuousClock()
        let start = clock.now
        if let rejection = await tryPublish(probe, on: peer) {
            Issue.record("[LIVE] probe kind-9 publish rejected: \(rejection)")
            await live.engine.stop(); await peer.stop()
            return
        }
        let arrived = await poll(timeout: .seconds(5)) {
            ((try? await store.event(id: probe.id)) ?? nil) != nil
        }
        let elapsed = clock.now - start
        print("[LIVE] probe kind-9 \(probe.id.prefix(8)) arrived=\(arrived) latency=\(elapsed)")

        #expect(arrived, "the probe kind-9 never reached the store via the per-channel sub")
        #expect(elapsed < .seconds(1), "per-channel live delivery latency \(elapsed) exceeded 1s")

        await live.engine.stop()
        await peer.stop()
    }

    /// Connects the second connection, self-provisions the channel (kind 9007), and
    /// seeds it into `channel_sync` so the engine's standing content sub registers
    /// independent of discovery timing. Returns the connection, or `nil` (recording
    /// the reason) on failure.
    private func provision(
        channel: String, signer: some EventSigner, store: BuzzEventStore
    ) async -> RelayConnection? {
        let peer = RelayConnection(url: LiveRelay.wsURL, signer: signer)
        guard await connectAndWaitReady(peer) else {
            Issue.record("[LIVE] peer connection never reached ready — relay unreachable or auth failed")
            return nil
        }
        do {
            let create = try await createChannelEvent(
                channel: channel, name: "livesub-\(channel.prefix(8))", signer: signer
            )
            if let rejection = await tryPublish(create, on: peer) {
                Issue.record("[LIVE] channel self-provision (kind 9007) rejected: \(rejection)")
                await peer.stop()
                return nil
            }
            try await store.executeForTest("""
            INSERT OR IGNORE INTO channel_sync (channel_id, watermark_created_at, watermark_id, head_synced)
            VALUES ('\(channel)', NULL, NULL, 0)
            """)
            return peer
        } catch {
            Issue.record("[LIVE] provision threw: \(error)")
            await peer.stop()
            return nil
        }
    }
}
