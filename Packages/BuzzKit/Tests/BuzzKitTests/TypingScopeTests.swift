@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// How a typing indicator is *scoped*, and what ends one.
///
/// Split from ``PresenceStoreTests`` because it is a subject rather than a handful of
/// cases: typing is keyed `(channel, thread, pubkey)`, so an agent working in a thread
/// and a person writing in the channel around it are two audiences — and a message is
/// read as the end of its author's typing in the scope it landed in, which is what stops
/// the strip from sitting under the reply it was announcing for the rest of the TTL.
@Suite("Typing scope and completion", .timeLimit(.minutes(1)))
struct TypingScopeTests {
    @Test("a thread hears only its own writers; the channel hears all of them")
    func typingScopesPerThread() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()
        // The shape the agent harness publishes for a thread reply, and the shape a
        // channel-level composer publishes.
        let inThread = try alice.event(.typing, "", tags: [["h", "room-1"], ["e", "root-1", "", "reply"]])
        let inChannel = try bob.event(.typing, "", tags: [["h", "room-1"]])

        await store.apply([inThread, inChannel])

        // The thread is exact — the channel's own writer is not in it.
        #expect(await store.typingSnapshot(in: "room-1", thread: "root-1") == [alice.pubkey])
        #expect(await store.typingSnapshot(in: "room-1", thread: "root-2").isEmpty)
        // The channel is the whole channel, threads included: from there a reader cannot
        // tell which thread the work is in, and would otherwise be told nothing at all.
        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey, bob.pubkey].sorted())
        #expect(await store.typingSnapshot(in: "room-2").isEmpty)
    }

    @Test("one person writing in two threads is one typer on the channel")
    func channelDeduplicatesAcrossThreads() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()

        await store.apply([
            try alice.event(.typing, "", tags: [["h", "room-1"], ["e", "root-1", "", "reply"]]),
            try alice.event(.typing, "", tags: [["h", "room-1"], ["e", "root-2", "", "reply"]]),
        ])

        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey])
    }

    @Test("a thread's typer reaches the channel's observers too, and leaves with them")
    func channelObserverHearsThreadTyping() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()

        let stream = await store.typing(in: "room-1")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        let tags = [["h", "room-1"], ["e", "root-1", "", "reply"]]
        await store.apply([try alice.event(.typing, "", tags: tags, at: 100)])
        #expect(await iterator.next() == [alice.pubkey])

        // And the reply landing in that thread takes it off the channel's strip as well.
        let reply = try alice.event(.channelMessage, "done", tags: tags, at: 101)
        await store.messagesArrived([reply])
        #expect(await iterator.next() == [])
    }

    @Test("a reply deep in a thread scopes to the thread's root, not its parent")
    func typingScopesToRootMarker() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        // Nested: root marker plus a reply marker naming a message inside the thread.
        // The reader has the *thread* open, so the root is the scope that matters.
        let nested = try alice.event(.typing, "", tags: [
            ["h", "room-1"],
            ["e", "root-1", "", "root"],
            ["e", "reply-7", "", "reply"],
        ])

        await store.apply([nested])

        #expect(await store.typingSnapshot(in: "room-1", thread: "root-1") == [alice.pubkey])
        #expect(await store.typingSnapshot(in: "room-1", thread: "reply-7").isEmpty)
    }

    // MARK: - A message ends its author's typing

    @Test("a message clears its author's typing in the scope it landed in")
    func messageClearsTyping() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        let bob = try Fixture()
        await store.apply([
            try alice.event(.typing, "", tags: [["h", "room-1"]], at: 100),
            try bob.event(.typing, "", tags: [["h", "room-1"]], at: 100),
        ])
        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey, bob.pubkey].sorted())

        await store.messagesArrived([try alice.message("here it is", in: "room-1", at: 101)])

        // Alice is done; Bob is still writing. The TTL has not moved.
        #expect(await store.typingSnapshot(in: "room-1") == [bob.pubkey])
    }

    @Test("a channel message leaves the author's typing in a thread alone")
    func messageClearsOnlyItsOwnScope() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        await store.apply([
            try alice.event(.typing, "", tags: [["h", "room-1"]], at: 100),
            try alice.event(.typing, "", tags: [["h", "room-1"], ["e", "root-1", "", "reply"]], at: 100),
        ])

        await store.messagesArrived([try alice.message("channel-level", in: "room-1", at: 101)])

        // Read through the records rather than a snapshot: the channel's audience spans
        // its threads, so it would still report Alice on the strength of the thread
        // record alone, and that is exactly the record this must not have touched.
        let scopes = await Set(store.typingRecords.keys.map(\.scope))
        #expect(scopes == [PresenceStore.TypingScope(channel: "room-1", thread: "root-1")])
        #expect(await store.typingSnapshot(in: "room-1", thread: "root-1") == [alice.pubkey])
    }

    @Test("a typing indicator published no later than the message it announces is refused")
    func typingBehindItsOwnMessageIsRefused() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        // The race this exists for: a client publishes typing on a timer and its message
        // the moment the text is ready, so the last indicator of a turn routinely arrives
        // *after* the message it was announcing.
        await store.messagesArrived([try alice.message("here it is", in: "room-1", at: 200)])

        await store.apply([try alice.event(.typing, "", tags: [["h", "room-1"]], at: 200)])

        #expect(await store.typingSnapshot(in: "room-1").isEmpty)
    }

    @Test("typing published after the message shows again — a second turn is not suppressed")
    func typingAfterTheMessageStillShows() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()
        await store.messagesArrived([try alice.message("first", in: "room-1", at: 200)])

        await store.apply([try alice.event(.typing, "", tags: [["h", "room-1"]], at: 201)])

        #expect(await store.typingSnapshot(in: "room-1") == [alice.pubkey])
    }

    @Test("a message that clears a typer wakes that scope's observers")
    func messageNotifiesTypingObservers() async throws {
        let clock = MutableClock()
        let store = PresenceStore(now: { clock.current })
        let alice = try Fixture()

        let stream = await store.typing(in: "room-1")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        await store.apply([try alice.event(.typing, "", tags: [["h", "room-1"]], at: 100)])
        #expect(await iterator.next() == [alice.pubkey])

        await store.messagesArrived([try alice.message("done", in: "room-1", at: 101)])
        #expect(await iterator.next() == [])
    }

    @Test("a sweep past the TTL drops the marks a message left behind")
    func sweepEvictsMessageMarks() async throws {
        let clock = MutableClock()
        let store = PresenceStore(typingTTL: .seconds(8), now: { clock.current })
        let alice = try Fixture()
        await store.messagesArrived([try alice.message("done", in: "room-1", at: 200)])
        #expect(await store.messageMarks.count == 1)

        clock.advance(by: .seconds(9))
        await store.sweep()

        // Nothing a lapsed mark could still refuse: a typing event old enough to be
        // covered by it is already past its own TTL on arrival.
        #expect(await store.messageMarks.isEmpty)
    }

}
