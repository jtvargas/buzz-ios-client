@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Presence heartbeat", .timeLimit(.minutes(1)))
struct PresenceHeartbeatTests {
    @Test("a beat publishes online presence, channel-less")
    func beatsOnline() async {
        let spy = RecordingEphemeralPublisher()
        let heartbeat = PresenceHeartbeat(publisher: spy)

        await heartbeat.beat()

        #expect(await spy.publishes == [
            .init(kind: .presence, content: "online", tags: [["status", "online"]]),
        ])
    }

    @Test("going offline publishes an offline departure")
    func goesOffline() async {
        let spy = RecordingEphemeralPublisher()
        let heartbeat = PresenceHeartbeat(publisher: spy)

        await heartbeat.goOffline()

        #expect(await spy.publishes == [
            .init(kind: .presence, content: "offline", tags: [["status", "offline"]]),
        ])
    }

    @Test("beats at the injected cadence while foregrounded")
    func beatsAtCadence() async {
        let spy = RecordingEphemeralPublisher()
        // Permit exactly three cadence sleeps, then end the loop: an initial beat
        // plus one after each permitted sleep is four online heartbeats.
        let ticks = TickGate(allowed: 3)
        let heartbeat = PresenceHeartbeat(
            publisher: spy,
            interval: .seconds(60),
            sleep: { _ in try await ticks.tick() }
        )

        await heartbeat.runForeground()

        #expect(await spy.online() == 4)
        #expect(await spy.offline() == 0)
    }

    @Test("stops beating on background and publishes exactly one offline")
    func foregroundOnly() async {
        let spy = RecordingEphemeralPublisher()
        // A real, cancellable sleep: after the first beat the loop parks in it until
        // stopBackground() cancels, so no second online beat can slip out.
        let heartbeat = PresenceHeartbeat(publisher: spy, sleep: { try await Task.sleep(for: $0) })

        heartbeat.startForeground()
        await waitUntil { await spy.online() >= 1 }

        await heartbeat.stopBackground()

        #expect(await spy.online() == 1)
        #expect(await spy.offline() == 1)
    }
}
