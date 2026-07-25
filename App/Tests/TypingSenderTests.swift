import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Typing sender", .timeLimit(.minutes(1)))
struct TypingSenderTests {
    @Test("throttles own typing: rapid input publishes once, a later keystroke republishes")
    func throttles() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let clock = ManualClock()
        let spy = RecordingEphemeralPublisher()
        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: StubSender(),
            typing: spy,
            typingThrottle: .seconds(3),
            clock: { clock.current }
        )

        model.handleTyping("h")
        model.handleTyping("he") // within the throttle window: suppressed
        model.handleTyping("hel") // within the throttle window: suppressed
        await waitUntil { await spy.count == 1 }
        #expect(await spy.count == 1)

        // Past the throttle window, the next keystroke republishes.
        clock.advance(by: .seconds(3))
        model.handleTyping("hell")
        await waitUntil { await spy.count == 2 }

        // Every publish is a channel-scoped typing indicator (S-5: the `h` tag is
        // required, or the relay rejects a non-member's typing).
        let publishes = await spy.publishes
        #expect(publishes.allSatisfy {
            $0.kind == .typing && $0.content == "" && $0.tags == [["h", "room-1"]]
        })
    }

    @Test("empty or whitespace input never publishes typing")
    func emptyNeverPublishes() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let spy = RecordingEphemeralPublisher()
        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: StubSender(),
            typing: spy
        )

        // The empty-input guard returns before spawning any publish task.
        model.handleTyping("")
        model.handleTyping("   ")
        #expect(await spy.count == 0)
    }
}
