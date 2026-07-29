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
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await withLiveChannelFixture(namePrefix: "livesub", signer: signer) { fixture in
            let channel = fixture.channelID
            let live = LiveEngine(store: store, signer: signer)
            try await live.engine.start()
            guard await poll(timeout: .seconds(30), { await live.engine.state == .running }) else {
                Issue.record("[LIVE] engine never reached running")
                await live.engine.stop()
                return
            }
            let registered = await poll(timeout: .seconds(30)) {
                await live.engine.channelContentSubscriptions[channel] != nil
            }
            guard registered else {
                Issue.record("[LIVE] per-channel content sub never registered for \(channel)")
                await live.engine.stop()
                return
            }
            try await Task.sleep(for: .seconds(2))

            let probe = try await channelMessageEvent(
                "live-sub probe \(UUID().uuidString.prefix(8))", channel: channel, signer: signer
            )
            let clock = ContinuousClock()
            let start = clock.now
            if let rejection = await tryPublish(probe, on: fixture.connection) {
                Issue.record("[LIVE] probe kind-9 publish rejected: \(rejection)")
                await live.engine.stop()
                return
            }
            let arrived = await poll(timeout: .seconds(5)) {
                ((try? await store.event(id: probe.id)) ?? nil) != nil
            }
            let elapsed = clock.now - start

            #expect(arrived, "the probe kind-9 never reached the store via the per-channel sub")
            #expect(elapsed < .seconds(1), "per-channel live delivery latency \(elapsed) exceeded 1s")
            await live.engine.stop()
        }
    }
}
