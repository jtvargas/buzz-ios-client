@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("PresenceStore", .timeLimit(.minutes(1)))
struct PresenceStoreTests {
    // MARK: - Apply

    @Test("records a presence heartbeat under (channel, pubkey) with its status")
    func recordsPresence() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let event = try alice.event(.presence, "online", tags: [["h", "room-1"]])

        await store.apply([event])

        let snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.present == [PresenceMember(pubkey: alice.pubkey, status: .online)])
        #expect(snapshot.typing.isEmpty)
    }

    @Test("records a typing indicator and keeps presence and typing separate")
    func recordsTyping() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()
        let presence = try alice.event(.presence, "online", tags: [["h", "room-1"]])
        let typing = try bob.event(.typing, "", tags: [["h", "room-1"]])

        await store.apply([presence, typing])

        let snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.present == [PresenceMember(pubkey: alice.pubkey, status: .online)])
        #expect(snapshot.typing == [bob.pubkey])
    }

    @Test("reads the status from a status tag when the content is empty")
    func statusFromTag() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let event = try alice.event(.presence, "", tags: [["h", "room-1"], ["status", "away"]])

        await store.apply([event])

        let snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.present == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    @Test("preserves an unrecognised status rather than dropping it")
    func preservesUnknownStatus() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let event = try alice.event(.presence, "brb", tags: [["h", "room-1"]])

        await store.apply([event])

        let snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.present == [PresenceMember(pubkey: alice.pubkey, status: .other("brb"))])
    }

    @Test("scopes state per channel")
    func scopesPerChannel() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let here = try alice.event(.presence, "online", tags: [["h", "room-1"]])
        let there = try alice.event(.presence, "away", tags: [["h", "room-2"]])

        await store.apply([here, there])

        let room1 = await store.snapshot(for: "room-1")
        let room2 = await store.snapshot(for: "room-2")
        #expect(room1.present == [PresenceMember(pubkey: alice.pubkey, status: .online)])
        #expect(room2.present == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    @Test("ignores an ephemeral with no channel and non-presence/typing kinds")
    func ignoresUnscopedAndForeign() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        // No `h` tag: nowhere to place it.
        let unscoped = try alice.event(.presence, "online")
        // An ephemeral kind that is not presence or typing.
        let foreign = try alice.event(EventKind(rawValue: 20050), "x", tags: [["h", "room-1"]])

        await store.apply([unscoped, foreign])

        let snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.isEmpty)
    }

    // MARK: - Newest-wins staleness guard

    @Test("a newer status supersedes an older one; a replayed older one is ignored")
    func newestStatusWins() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let online = try alice.event(.presence, "online", tags: [["h", "room-1"]], at: 100)
        let away = try alice.event(.presence, "away", tags: [["h", "room-1"]], at: 200)
        // Older than `away`, e.g. redelivered after a reconnect.
        let staleOnline = try alice.event(.presence, "online", tags: [["h", "room-1"]], at: 150)

        await store.apply([online, away, staleOnline])

        let snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.present == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    @Test("an offline heartbeat clears the peer; a stale offline does not")
    func offlineClears() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let online = try alice.event(.presence, "online", tags: [["h", "room-1"]], at: 200)
        let offline = try alice.event(.presence, "offline", tags: [["h", "room-1"]], at: 300)

        await store.apply([online])
        #expect(await store.snapshot(for: "room-1").present.count == 1)

        // A stale offline (older than the live online) must not evict.
        let staleOffline = try alice.event(.presence, "offline", tags: [["h", "room-1"]], at: 100)
        await store.apply([staleOffline])
        #expect(await store.snapshot(for: "room-1").present.count == 1)

        await store.apply([offline])
        #expect(await store.snapshot(for: "room-1").isEmpty)
    }

    // MARK: - Expiry (lazy, on read)

    @Test("typing lapses at its TTL while presence outlives it")
    func typingLapsesBeforePresence() async throws {
        let clock = MutableClock()
        let store = PresenceStore(
            presenceTTL: .seconds(60),
            typingTTL: .seconds(10),
            now: { clock.current }
        )
        let alice = try Fixture()
        let presence = try alice.event(.presence, "online", tags: [["h", "room-1"]])
        let typing = try alice.event(.typing, "", tags: [["h", "room-1"]])

        await store.apply([presence, typing])

        // Just before the typing TTL: both live.
        clock.advance(by: .seconds(9))
        var snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.typing == [alice.pubkey])
        #expect(snapshot.present.count == 1)

        // At the typing TTL: typing is gone, presence remains.
        clock.advance(by: .seconds(1))
        snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.typing.isEmpty)
        #expect(snapshot.present.count == 1)

        // At the presence TTL: presence is gone too.
        clock.advance(by: .seconds(50))
        snapshot = await store.snapshot(for: "room-1")
        #expect(snapshot.isEmpty)
    }

    @Test("a fresh heartbeat refreshes the TTL from the moment of receipt")
    func heartbeatRefreshesTTL() async throws {
        let clock = MutableClock()
        let store = PresenceStore(presenceTTL: .seconds(60), now: { clock.current })
        let alice = try Fixture()

        await store.apply([try alice.event(.presence, "online", tags: [["h", "room-1"]], at: 1000)])

        // Almost expired, then a second heartbeat lands.
        clock.advance(by: .seconds(59))
        await store.apply([try alice.event(.presence, "online", tags: [["h", "room-1"]], at: 2000)])

        // Past the first deadline but within the refreshed one.
        clock.advance(by: .seconds(2))
        #expect(await store.snapshot(for: "room-1").present.count == 1)
    }

    // MARK: - Observation (push, driven by sweep)

    @Test("an observer is seeded and then sees each change once")
    func observerSeesChanges() async throws {
        let clock = MutableClock()
        let store = PresenceStore(typingTTL: .seconds(10), now: { clock.current })
        let alice = try Fixture()

        let stream = await store.presence(for: "room-1")
        var iterator = stream.makeAsyncIterator()

        // Seeded with the empty snapshot the observer subscribed into.
        let seed = await iterator.next()
        #expect(seed?.isEmpty == true)

        await store.apply([try alice.event(.typing, "", tags: [["h", "room-1"]])])
        let afterApply = await iterator.next()
        #expect(afterApply?.typing == [alice.pubkey])

        // The indicator lapses; sweep pushes the shrink to the observer.
        clock.advance(by: .seconds(10))
        await store.sweep()
        let afterSweep = await iterator.next()
        #expect(afterSweep?.isEmpty == true)
    }

    @Test("a batch touching one channel wakes its observer once, coalesced")
    func batchCoalescesToOneYield() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()

        let stream = await store.presence(for: "room-1")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        await store.apply([
            try alice.event(.presence, "online", tags: [["h", "room-1"]]),
            try bob.event(.presence, "away", tags: [["h", "room-1"]]),
        ])

        // A single coalesced snapshot carrying both members proves the batch
        // published once — a per-event publish would have yielded Alice alone first.
        let snapshot = await iterator.next()
        #expect(snapshot?.present == [
            PresenceMember(pubkey: alice.pubkey, status: .online),
            PresenceMember(pubkey: bob.pubkey, status: .away),
        ].sorted { $0.pubkey < $1.pubkey })
    }

    @Test("sweep does not yield when nothing changed")
    func sweepIsQuietWhenUnchanged() async throws {
        let clock = MutableClock()
        let store = PresenceStore(presenceTTL: .seconds(60), now: { clock.current })
        let alice = try Fixture()

        let stream = await store.presence(for: "room-1")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        await store.apply([try alice.event(.presence, "online", tags: [["h", "room-1"]])])
        _ = await iterator.next() // the apply

        // Nothing has lapsed, so this sweep must not produce a spurious yield. The
        // next value the observer sees is the real change that follows it.
        await store.sweep()
        await store.apply([try alice.event(.presence, "away", tags: [["h", "room-1"]], at: 1_700_000_001)])
        let next = await iterator.next()
        #expect(next?.present == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    // MARK: - Ingest wiring seam

    @Test("ephemerals diverted by BuzzEventStore reach the presence store")
    func wiredFromEventStore() async throws {
        // The real divert path: BuzzEventStore verifies and diverts 20001/20002 into
        // IngestResult.ephemeral, which the sync engine will forward straight to
        // PresenceStore.apply. Exercise that seam end to end here.
        let database = TempDatabase()
        defer { database.remove() }
        let eventStore = try database.open()
        let clock = MutableClock()
        let presenceStore = PresenceStore(now: { clock.current })
        let alice = try Fixture()

        let presence = try alice.event(.presence, "online", tags: [["h", "room-1"]])
        let message = try alice.message("real", in: "room-1")

        let result = try await eventStore.ingest(batch: [presence, message], phase: .live)
        #expect(result.ephemeral.map(\.id) == [presence.id])

        await presenceStore.apply(result.ephemeral)

        let snapshot = await presenceStore.snapshot(for: "room-1")
        #expect(snapshot.present == [PresenceMember(pubkey: alice.pubkey, status: .online)])
    }
}

/// A hand-advanced monotonic clock, so a test controls presence and typing expiry
/// with no sleeps and no real time.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var current: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}
