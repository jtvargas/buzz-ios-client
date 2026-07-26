import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// The parts of the Slack-parity message pass that are logic rather than appearance:
/// the reply-preview participants arriving on the timeline's own observation, and the
/// conversation header's member-count line.
///
/// Deliberately not here: anything about how a row *looks*. Avatar size, the gutter a
/// day separator aligns to, the pressed dim on the name, and Liquid Glass rendering are
/// all layout and material questions that a unit test can only restate as the constants
/// it is asserting against. They are on the owner's device pass instead.
@MainActor
@Suite("Message surface reads", .timeLimit(.minutes(1)))
struct MessageSurfaceTests {
    /// A kind-9 reply threaded to `root` by NIP-10 marker.
    private func reply(
        _ author: Fixture,
        to root: NostrEvent,
        in channel: String = "room-1",
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage,
            "reply",
            tags: [["h", channel], ["e", root.id, "", "reply"]],
            at: seconds
        )
    }

    @Test("the reply preview's participants arrive on the timeline's own observation")
    func streamsReplyParticipants() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let root = try opener.message("root", in: "room-1", at: 1_000)
        let quiet = try opener.message("quiet", in: "room-1", at: 1_001)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            root,
            quiet,
            try reply(alice, to: root, at: 1_002),
        ], phase: .backfill)

        await waitUntil { model.participants(for: root.id) == [alice.pubkey] }
        // A message nobody replied to previews nobody — the read omits it, and the
        // accessor turns a missing key into an empty strip.
        #expect(model.participants(for: quiet.id).isEmpty)

        // A second person answering shows up without a second pipeline: the same commit
        // signal that carries the reply carries its author's face.
        let bob = try Fixture()
        _ = try await store.ingest(batch: [
            try reply(bob, to: root, at: 1_003),
        ], phase: .live)
        await waitUntil { model.participants(for: root.id) == [alice.pubkey, bob.pubkey] }
    }

    @Test("only threaded rows are asked about, so the read never becomes one query per row")
    func narrowsToThreadedRows() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let root = try opener.message("root", in: "room-1", at: 1_000)
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            root,
            try opener.message("one", in: "room-1", at: 1_001),
            try opener.message("two", in: "room-1", at: 1_002),
        ], phase: .backfill)

        // Three loaded rows, none of them threaded: nothing to ask the store about.
        await waitUntil { model.rows.count == 3 }
        #expect(model.threadedRowIDs.isEmpty)

        // A reply lands: the *same* commit that turns the root into a threaded row is the
        // one that puts it in the batch.
        _ = try await store.ingest(batch: [
            try reply(alice, to: root, at: 1_003),
        ], phase: .live)
        // Waited on the participants and not on `threadedRowIDs`: the merge that decides
        // which rows are threaded lands earlier in the same observation turn than the
        // read it drives, so the id set is briefly ahead of the faces.
        await waitUntil { model.participants(for: root.id) == [alice.pubkey] }
        #expect(model.threadedRowIDs == [root.id])
    }

    @Test("page one's reply previews are on screen on the first body pass")
    func primesReplyParticipants() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let root = try opener.message("root", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [
            root,
            try reply(alice, to: root, at: 1_001),
        ], phase: .backfill)

        // No `run()`: this is what the first `body` pass alone produces, so a threaded
        // message opens with its faces rather than gaining them a frame later.
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        model.primeIfNeeded()
        #expect(model.participants(for: root.id) == [alice.pubkey])
    }

    @Test("the header's member line counts members, and says nothing about an empty roster")
    func memberCountLine() {
        // Nothing rather than "0 members": an empty roster is the directory read not
        // having landed yet, and stating it as a fact reports a loading state as truth.
        #expect(ConversationHeaderPill.memberCount(0) == nil)
        #expect(ConversationHeaderPill.memberCount(1) == "1 member")
        #expect(ConversationHeaderPill.memberCount(2) == "2 members")
        #expect(ConversationHeaderPill.memberCount(12) == "12 members")
    }
}
