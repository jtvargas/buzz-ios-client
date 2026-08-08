import BuzzKit
@testable import Hive
import NostrCore
import Observation
import Testing

/// The affordance above the composer: when it is offered, where pressing it lands, and
/// what the press leaves behind.
///
/// Deliberately not here: how the pills look, and whether the scroll animation reads as
/// smooth. Those were settled in a harness against the shipping ``ConversationScaffold``
/// (`~/.buzz/.scratch/jumpharness`), which is also where the landing itself was proved —
/// `ScrollPosition.scrollTo(id:anchor:)` reaches the row but loses its anchor to
/// `defaultScrollAnchor(.bottom, for: .alignment)`, so the jump goes through a
/// `ScrollViewReader` instead. A unit test cannot see either fact.
@MainActor
@Suite("Conversation jump controls", .timeLimit(.minutes(1)))
struct ConversationJumpTests {
    // MARK: - When the control is offered

    @Test("the pill is offered for held-back arrivals and for nothing else")
    func controlFollowsTheCountAlone() {
        let state = ConversationJumpState()
        #expect(state.control == nil)

        // Held from about one message off the bottom, and at any distance past that:
        // how far the reader has scrolled is no longer an input. `↓ Latest` was the
        // only reader of the scaffold's half-viewport band and both are gone, so a
        // reader parked in history with nothing waiting is offered nothing.
        state.hold(count: 1, firstID: "a")
        #expect(state.control == .unread(1))

        state.hold(count: 3, firstID: "c")
        #expect(state.control == .unread(3))

        // Released by hand, the way `jumpToNewMessages()` releases it.
        state.hold(count: 0, firstID: nil)
        #expect(state.control == nil)
    }

    @Test("the pill counts in words a person reads")
    func pluralisation() {
        #expect(NewMessagesPill.label(count: 1) == "1 new message")
        #expect(NewMessagesPill.label(count: 2) == "2 new messages")
        #expect(NewMessagesPill.label(count: 12) == "12 new messages")
    }

    // MARK: - Where a press lands

    @Test("pressing the unread pill lands on the first arrival, not the newest")
    func jumpsToFirstUnread() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("read", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded && model.rows.count == 1 }

        model.isAtBottom = false
        let first = try author.message("first new", in: "room-1", at: 1_001)
        _ = try await store.ingest(batch: [
            first,
            try author.message("second new", in: "room-1", at: 1_002),
            try author.message("third new", in: "room-1", at: 1_003),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 3 }
        #expect(model.jump.firstUnreadID == first.id)

        model.jumpToNewMessages()

        // Everything is rendered — it is a boundary, not a filter — and the scroll is
        // aimed at the oldest arrival rather than at the bottom past all three.
        #expect(model.rows.map(\.content) == ["read", "first new", "second new", "third new"])
        #expect(model.jumpTarget == .message(first.id, animated: true))
        #expect(model.jumpToken == 1)
        #expect(model.jump.unreadCount == 0)

        // And the reader is still where they now are: reporting them at the bottom would
        // be a lie the scaffold immediately contradicts, and it is the scaffold's
        // geometry that says otherwise a frame later.
        #expect(model.isAtBottom == false)

        // The boundary re-armed at what is now the newest row, so reading the three they
        // just asked for is not interrupted by a fourth.
        _ = try await store.ingest(batch: [
            try author.message("fourth", in: "room-1", at: 1_004),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 1 }
        #expect(model.rows.map(\.content) == ["read", "first new", "second new", "third new"])
    }

    /// No control calls this any more. It stays because an own send does — see
    /// ``ChannelTimelineModel/shouldJumpToOwnSend`` — and because it is where a press
    /// that raced the reader back to the bottom lands.
    @Test("a jump to the newest message goes to the bottom and releases the freeze")
    func latestGoesToTheBottom() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        model.primeIfNeeded()
        model.isAtBottom = false

        model.jumpToLatest()
        #expect(model.jumpTarget == .bottom)
        #expect(model.jumpToken == 1)
        #expect(model.isAtBottom)
    }

    @Test("with nothing held back the unread press still has somewhere to go")
    func jumpWithoutUnreadFallsBackToTheBottom() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        model.primeIfNeeded()
        model.isAtBottom = false

        // Nothing is waiting — a press that raced the reader scrolling back to the
        // bottom. Landing at the bottom is the honest answer; doing nothing leaves a
        // pressed control that did not move.
        model.jumpToNewMessages()
        #expect(model.jumpTarget == .bottom)
        #expect(model.jumpToken == 1)
    }

    // MARK: - A thread offers the same controls

    @Test("a thread's pill lands on the first held-back reply too")
    func threadJumpsToFirstUnread() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("opener", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let model = ThreadModel(
            root: root.id,
            channel: "room-1",
            store: store,
            sender: StubSender(),
            opener: StubThreadOpener(store: store, events: []),
            selfPubkey: nil
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded && model.rows.count == 1 }

        model.isAtBottom = false
        let reply = try author.event(
            .channelMessage,
            "first reply",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
            at: 1_001
        )
        _ = try await store.ingest(batch: [
            reply,
            try author.event(
                .channelMessage,
                "second reply",
                tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
                at: 1_002
            ),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 2 }

        model.jumpToNewMessages()
        #expect(model.jumpTarget == .message(reply.id, animated: true))
        #expect(model.jump.unreadCount == 0)
        #expect(model.rows.count == 3)
    }

    // MARK: - What a moving count must not touch

    @Test("an arrival behind the freeze moves the count and nothing the list renders")
    func heldArrivalDoesNotInvalidateTheList() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded && model.rows.count == 1 }
        model.isAtBottom = false

        // Exactly what a message row's body reads. Observation notifies per property
        // touched, so this is the same dependency the list itself registers — including
        // the three dictionaries the observation re-reads on *every* commit, whose
        // unconditional writes used to invalidate every row for an unchanged value.
        // A reference box, because Observation hands its change notification to a
        // `@Sendable` closure that cannot capture a mutable local.
        let listInvalidated = Flag()
        withObservationTracking {
            _ = model.items
            _ = model.rows
            _ = model.reactionGroups
            _ = model.mentionRefs
            _ = model.replyParticipants
            _ = model.hasLoaded
            _ = model.hasMoreOlder
        } onChange: {
            listInvalidated.raise()
        }

        let countInvalidated = Flag()
        withObservationTracking {
            _ = model.jump.unreadCount
        } onChange: {
            countInvalidated.raise()
        }

        _ = try await store.ingest(batch: [
            try author.message("held", in: "room-1", at: 1_001),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 1 }
        // A real suspension, so anything the commit was going to write has written.
        await parkBriefly()

        #expect(countInvalidated.isRaised)
        #expect(!listInvalidated.isRaised)
    }
}

/// A `Bool` an Observation change handler can set: its `onChange` is `@Sendable`, so a
/// captured `var` will not do.
private final class Flag: @unchecked Sendable {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}
