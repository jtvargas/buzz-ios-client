import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// Reaching one particular message from somewhere else: when the walk back through history
/// stops, and which of the two endings it reports when it stops without the message.
///
/// The landing itself — the scroll, the anchor, the highlight — is not here. That is
/// ``ConversationJumpTests``' ground and the scaffold harness's, and neither can be seen
/// from a model. What *can* only be seen here is the terminator, which is where the first
/// version of this got it wrong: it read an ordinary pass that happened to load nothing as
/// the end of history and told the reader a message that was one page further back did not
/// exist.
@MainActor
@Suite("Reaching a message from search", .timeLimit(.minutes(1)))
struct ConversationFocusTests {
    /// Spins until `condition` holds or the deadline passes — the bounded shape, so a
    /// predicate that never comes true fails its assertion instead of hanging out the suite's
    /// whole time limit.
    static func waitUntil(
        _ condition: @MainActor () async -> Bool,
        within seconds: Double = 5
    ) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 120 messages a second apart in `room-1`, oldest `m0` at 1_000.
    private func seed(_ store: BuzzEventStore) async throws -> [NostrEvent] {
        let author = try Fixture()
        var batch: [NostrEvent] = []
        for index in 0 ..< 120 {
            batch.append(try author.message("m\(index)", in: "room-1", at: 1_000 + Int64(index)))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)
        return batch
    }

    // MARK: - Stopping on a proof

    @Test("the walk stops as soon as it has loaded past where the message would be")
    func stopsAtTheTimestampRatherThanAtTheEndOfHistory() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await seed(store)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 50
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await Self.waitUntil { model.rows.count == 50 }

        // A message that is not in this channel at all, sent at m60's second. The head holds
        // m70…m119, so the first older page — m20…m69 — carries the floor past it.
        let outcome = await model.focus(on: "absent-event", sentAt: 1_060)

        #expect(outcome == .gaveUp)
        // Exactly one older page. The proof is the floor, not exhaustion: without the
        // timestamp the only way to be sure would be to walk all 120 rows and then some.
        #expect(model.rows.count == 100)
        #expect(model.hasMoreOlder)
    }

    @Test("a message the channel does not hold is reported as not found")
    func reportsNotFoundWhenItWalksPast() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await seed(store)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 50
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await Self.waitUntil { model.rows.count == 50 }

        // Observed while the walk is still running: the report clears itself after a moment,
        // so by the time `focus` returns there is nothing left on the surface to read.
        let walk = Task { await model.focus(on: "absent-event", sentAt: 1_060) }
        defer { walk.cancel() }
        await Self.waitUntil { model.jump.seek == .failed(.notFound) }
        #expect(model.jump.seek == .failed(.notFound))
    }

    // MARK: - Not mistaking a stall for an answer

    @Test("a pager that never lands a row is unreachable, not missing")
    func aStalledPagerIsNotAProofOfAbsence() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        _ = try await seed(store)

        let pager = StallingPager()
        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: StubSender(),
            history: pager,
            pageSize: 50
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await Self.waitUntil { model.rows.count == 50 }

        // Older than everything this device holds, so the walk exhausts the local pages and
        // then depends entirely on a relay that answers "there is more" and lands nothing.
        let walk = Task { await model.focus(on: "absent-event", sentAt: 1) }
        defer { walk.cancel() }

        await Self.waitUntil { model.jump.seek == .failed(.unreachable) }
        // The distinction this suite exists for. The old walk stopped at the first stall and
        // said `Message not found`, which claims a proof it does not have: a relay that will
        // not answer says nothing whatever about whether the message is there.
        #expect(model.jump.seek == .failed(.unreachable))

        // And it did not stop at the first stall.
        #expect(await pager.calls > ChannelTimelineModel.olderPageBudget)
    }
}

/// A relay that is reachable and always says there is more, but never lands a row — the
/// shape of a crowded boundary second, or of a stretch a reconcile has already filled.
///
/// ``ChannelTimelineModel/loadOlder()`` treats this as ordinary and keeps its own budget for
/// it; the walk above must do the same rather than reading one empty pass as the end.
private actor StallingPager: ChannelHistoryPaging {
    private(set) var calls = 0

    func loadOlderHistory(channel _: String, before _: WindowCursor) async throws -> SyncEngine.OlderHistoryPage {
        calls += 1
        return SyncEngine.OlderHistoryPage(hasMore: true, ingested: 0)
    }
}
