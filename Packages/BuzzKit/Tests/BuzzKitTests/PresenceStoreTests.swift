@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("PresenceStore", .timeLimit(.minutes(1)))
struct PresenceStoreTests {
    // MARK: - Keying split (S-5)

    @Test("presence keys globally by pubkey and accepts an h-less event")
    func presenceIsWorkspaceGlobal() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        // Upstream presence carries no `h` tag — the store must still record it.
        let event = try alice.event(.presence, "online")

        await store.apply([event])

        #expect(await store.workspacePresenceSnapshot() == [PresenceMember(pubkey: alice.pubkey, status: .online)])
    }

    @Test("a presence event's h tag is ignored — presence is not channel-scoped")
    func presenceIgnoresChannelTag() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        // Even if a peer tags presence with a channel, it lands in the one global
        // roster, not under that channel.
        let event = try alice.event(.presence, "online", tags: [["h", "room-1"]])

        await store.apply([event])

        #expect(await store.workspacePresenceSnapshot() == [PresenceMember(pubkey: alice.pubkey, status: .online)])
    }

    @Test("typing keys per (channel, pubkey) and requires a channel")
    func typingIsChannelScoped() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()
        let hereTyping = try alice.event(.typing, "", tags: [["h", "room-1"]])
        // No `h` tag: the relay would reject it, and there is nowhere to place it.
        let unscopedTyping = try bob.event(.typing, "")

        await store.apply([hereTyping, unscopedTyping])

        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey])
        #expect(await store.typingSnapshot(in: "room-2").isEmpty)
    }

    @Test("presence and typing are independent stores")
    func presenceAndTypingSeparate() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()
        let presence = try alice.event(.presence, "online")
        let typing = try bob.event(.typing, "", tags: [["h", "room-1"]])

        await store.apply([presence, typing])

        #expect(await store.workspacePresenceSnapshot() == [PresenceMember(pubkey: alice.pubkey, status: .online)])
        #expect(await store.typingSnapshot(in: "room-1") == [bob.pubkey])
    }

    @Test("typing is scoped per channel")
    func typingScopesPerChannel() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let here = try alice.event(.typing, "", tags: [["h", "room-1"]])
        let there = try alice.event(.typing, "", tags: [["h", "room-2"]])

        await store.apply([here, there])

        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey])
        #expect(await store.typingSnapshot(in: "room-2") == [alice.pubkey])
    }

    @Test("reads the status from a status tag when the content is empty")
    func statusFromTag() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let event = try alice.event(.presence, "", tags: [["status", "away"]])

        await store.apply([event])

        #expect(await store.workspacePresenceSnapshot() == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    @Test("preserves an unrecognised status rather than dropping it")
    func preservesUnknownStatus() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let event = try alice.event(.presence, "brb")

        await store.apply([event])

        let roster = await store.workspacePresenceSnapshot()
        #expect(roster == [PresenceMember(pubkey: alice.pubkey, status: .other("brb"))])
    }

    @Test("ignores a non-presence, non-typing ephemeral kind")
    func ignoresForeignEphemeral() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let foreign = try alice.event(EventKind(rawValue: 20050), "x", tags: [["h", "room-1"]])

        await store.apply([foreign])

        #expect(await store.workspacePresenceSnapshot().isEmpty)
        #expect(await store.typingSnapshot(in: "room-1").isEmpty)
    }

    // MARK: - Newest-wins staleness guard

    @Test("a newer presence status supersedes an older one; a replayed older one is ignored")
    func newestPresenceWins() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let online = try alice.event(.presence, "online", at: 100)
        let away = try alice.event(.presence, "away", at: 200)
        let staleOnline = try alice.event(.presence, "online", at: 150)

        await store.apply([online, away, staleOnline])

        #expect(await store.workspacePresenceSnapshot() == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    @Test("an offline heartbeat clears the peer from the roster; a stale offline does not")
    func offlineClears() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let online = try alice.event(.presence, "online", at: 200)
        let offline = try alice.event(.presence, "offline", at: 300)

        await store.apply([online])
        #expect(await store.workspacePresenceSnapshot().count == 1)

        let staleOffline = try alice.event(.presence, "offline", at: 100)
        await store.apply([staleOffline])
        #expect(await store.workspacePresenceSnapshot().count == 1)

        await store.apply([offline])
        #expect(await store.workspacePresenceSnapshot().isEmpty)
    }

    // MARK: - Expiry (lazy, on read)

    @Test("typing lapses at its TTL while presence outlives it")
    func typingLapsesBeforePresence() async throws {
        let clock = MutableClock()
        let store = PresenceStore(
            presenceTTL: .seconds(150),
            typingTTL: .seconds(8),
            now: { clock.current }
        )
        let alice = try Fixture()
        let presence = try alice.event(.presence, "online")
        let typing = try alice.event(.typing, "", tags: [["h", "room-1"]])

        await store.apply([presence, typing])

        // Just before the typing TTL: both live.
        clock.advance(by: .seconds(7))
        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey])
        #expect(await store.workspacePresenceSnapshot().count == 1)

        // At the typing TTL: typing is gone, presence remains.
        clock.advance(by: .seconds(1))
        #expect(await store.typingSnapshot(in: "room-1").isEmpty)
        #expect(await store.workspacePresenceSnapshot().count == 1)

        // At the presence TTL: presence is gone too.
        clock.advance(by: .seconds(142))
        #expect(await store.workspacePresenceSnapshot().isEmpty)
    }

    @Test("a fresh heartbeat refreshes the presence TTL from the moment of receipt")
    func heartbeatRefreshesTTL() async throws {
        let clock = MutableClock()
        let store = PresenceStore(presenceTTL: .seconds(150), now: { clock.current })
        let alice = try Fixture()

        await store.apply([try alice.event(.presence, "online", at: 1000)])

        // Almost expired, then a second heartbeat lands.
        clock.advance(by: .seconds(149))
        await store.apply([try alice.event(.presence, "online", at: 2000)])

        // Past the first deadline but within the refreshed one.
        clock.advance(by: .seconds(2))
        #expect(await store.workspacePresenceSnapshot().count == 1)
    }

    // MARK: - Observation (push, driven by sweep)

    @Test("a presence observer is seeded and then sees each change once")
    func presenceObserverSeesChanges() async throws {
        let clock = MutableClock()
        let store = PresenceStore(presenceTTL: .seconds(150), now: { clock.current })
        let alice = try Fixture()

        let stream = await store.workspacePresence()
        var iterator = stream.makeAsyncIterator()

        let seed = await iterator.next()
        #expect(seed?.isEmpty == true)

        await store.apply([try alice.event(.presence, "online")])
        let afterApply = await iterator.next()
        #expect(afterApply == [PresenceMember(pubkey: alice.pubkey, status: .online)])

        // The heartbeat lapses; sweep pushes the shrink to the observer.
        clock.advance(by: .seconds(150))
        await store.sweep()
        let afterSweep = await iterator.next()
        #expect(afterSweep?.isEmpty == true)
    }

    @Test("a typing observer sees a lapse pushed by sweep")
    func typingObserverSeesLapse() async throws {
        let clock = MutableClock()
        let store = PresenceStore(typingTTL: .seconds(8), now: { clock.current })
        let alice = try Fixture()

        let stream = await store.typing(in: "room-1")
        var iterator = stream.makeAsyncIterator()

        let seed = await iterator.next()
        #expect(seed?.isEmpty == true)

        await store.apply([try alice.event(.typing, "", tags: [["h", "room-1"]])])
        let afterApply = await iterator.next()
        #expect(afterApply == [alice.pubkey])

        clock.advance(by: .seconds(8))
        await store.sweep()
        let afterSweep = await iterator.next()
        #expect(afterSweep?.isEmpty == true)
    }

    @Test("a batch of presence heartbeats wakes the roster observer once, coalesced")
    func batchCoalescesToOneYield() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()

        let stream = await store.workspacePresence()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        await store.apply([
            try alice.event(.presence, "online"),
            try bob.event(.presence, "away"),
        ])

        // A single coalesced roster carrying both members proves the batch published
        // once — a per-event publish would have yielded Alice alone first.
        let snapshot = await iterator.next()
        #expect(snapshot == [
            PresenceMember(pubkey: alice.pubkey, status: .online),
            PresenceMember(pubkey: bob.pubkey, status: .away),
        ].sorted { $0.pubkey < $1.pubkey })
    }

    @Test("sweep does not yield when nothing changed")
    func sweepIsQuietWhenUnchanged() async throws {
        let clock = MutableClock()
        let store = PresenceStore(presenceTTL: .seconds(150), now: { clock.current })
        let alice = try Fixture()

        let stream = await store.workspacePresence()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        await store.apply([try alice.event(.presence, "online", at: 1000)])
        _ = await iterator.next() // the apply

        // Nothing has lapsed, so this sweep must not produce a spurious yield. The
        // next value the observer sees is the real change that follows it.
        await store.sweep()
        await store.apply([try alice.event(.presence, "away", at: 2000)])
        let next = await iterator.next()
        #expect(next == [PresenceMember(pubkey: alice.pubkey, status: .away)])
    }

    // MARK: - Ingest wiring seam

    @Test("ephemerals diverted by BuzzEventStore reach the presence store")
    func wiredFromEventStore() async throws {
        // The real divert path: BuzzEventStore verifies and diverts 20001/20002 into
        // IngestResult.ephemeral, which the sync engine forwards straight to
        // PresenceStore.apply. Exercise that seam end to end here.
        let database = TempDatabase()
        defer { database.remove() }
        let eventStore = try database.open()
        let clock = MutableClock()
        let presenceStore = PresenceStore(now: { clock.current })
        let alice = try Fixture()

        let presence = try alice.event(.presence, "online")
        let typing = try alice.event(.typing, "", tags: [["h", "room-1"]])
        let message = try alice.message("real", in: "room-1")

        let result = try await eventStore.ingest(batch: [presence, typing, message], phase: .live)
        #expect(result.ephemeral.map(\.id) == [presence.id, typing.id])

        await presenceStore.apply(result.ephemeral)

        let roster = await presenceStore.workspacePresenceSnapshot()
        #expect(roster == [PresenceMember(pubkey: alice.pubkey, status: .online)])
        #expect(await presenceStore.typingSnapshot(in: "room-1") == [alice.pubkey])
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
