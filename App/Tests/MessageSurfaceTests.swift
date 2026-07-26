import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// The parts of the Slack-parity message pass that are logic rather than appearance: the
/// reply-preview participants arriving on the timeline's own observation, the conversation
/// header's two lines, the row's tap arbitration, and the identifier the profile sheet
/// hands to the pasteboard.
///
/// Deliberately not here: anything about how a row *looks*. Avatar size, the pressed dim
/// on the name, and Liquid Glass rendering are layout and material questions that a unit
/// test can only restate as the constants it is asserting against. They are on the owner's
/// device pass instead — as is whether a gesture *fires*, which is why the arbitration
/// below is tested as the value it is rather than through a view host.
///
/// The day separator is the one geometry that is here, and only for the part that is a
/// *relationship* rather than an appearance: which of two shared lines its label starts on,
/// and that its air is derived from the list's rhythm instead of duplicated. Whether the
/// result reads as a heading is still a screenshot's answer.
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

    @Test("the day separator starts where an avatar starts, not where message text does")
    func daySeparatorAlignsToTheRow() {
        // The reported defect: the label was indented by the avatar gutter, which put the
        // day on the message *text* column with every avatar outdented to its left.
        let textColumn = MessageRowMetrics.rowLeading
            + MessageRowMetrics.avatarSize
            + MessageRowMetrics.avatarGap
        #expect(DaySeparatorView.leadingInset == MessageRowMetrics.rowLeading)
        #expect(DaySeparatorView.leadingInset < textColumn)

        // The rule is the label's underline: closer to the label than the pair is to the
        // messages around it. Reversed, the line reads as the boundary and the day as an
        // annotation on it, which is the shape this replaced.
        #expect(DaySeparatorView.labelToRule < DaySeparatorView.verticalAir)

        // And the air is derived from the list's own rhythm rather than being a literal
        // beside it: half of it on each side, so a boundary gets 1.5x an ordinary gap.
        #expect(DaySeparatorView.verticalAir * 2 == MessageRowMetrics.betweenMessages)
    }

    @Test("a control's action claims the tap for one window, and the row's tap for no longer")
    func rowTapArbitration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var arbitration = RowTapArbitration()

        // A tap on the message itself: nothing has claimed it, so the thread opens.
        #expect(arbitration.suppressesRowTap(now: now) == false)

        // A tap that landed on one of the row's controls — a chip, a link, Retry, or the
        // add-reaction pill's palette — is claimed, and the row's deferred tap on the next
        // main-actor turn must find it claimed.
        arbitration.controlDidAct(now: now)
        #expect(arbitration.suppressesRowTap(now: now))
        #expect(arbitration.suppressesRowTap(now: now + RowTapArbitration.window / 2))
        // And the claim expires, so the next deliberate tap on the message still works.
        #expect(arbitration.suppressesRowTap(now: now + RowTapArbitration.window) == false)
        #expect(arbitration.suppressesRowTap(now: now + 1) == false)

        // Two controls acting inside one window leave the later deadline standing, which is
        // what a flag with a timer behind it could not promise: the first one's reset would
        // land inside the second one's window.
        arbitration.controlDidAct(now: now)
        arbitration.controlDidAct(now: now + RowTapArbitration.window / 2)
        #expect(arbitration.suppressesRowTap(now: now + RowTapArbitration.window))
    }

    @Test("the profile sheet shows and copies the npub, truncated only for display")
    func profileKeyIsAnNpub() throws {
        let pubkey = String(repeating: "2b", count: 32)
        let key = ProfileSheetView.displayKey(for: pubkey)

        // The npub is what another client's "add a contact" field takes, so it is what the
        // one row whose whole purpose is to be copied has to carry.
        #expect(key.hasPrefix("npub1"))
        #expect(key != pubkey)
        let raw = try #require(Hex.decode(pubkey))
        #expect(key == NIP19.encodePublicKey(raw))
        // Case-insensitive on the way in, so an upper-case key from the wire still encodes.
        #expect(ProfileSheetView.displayKey(for: pubkey.uppercased()) == key)

        // The whole thing goes to the pasteboard; only the label is elided, and both ends
        // stay visible because they are the part people compare.
        let shown = ProfileSheetView.middleTruncated(key)
        #expect(shown.hasPrefix(String(key.prefix(12))))
        #expect(shown.hasSuffix(String(key.suffix(12))))
        #expect(shown.count == 25)
        #expect(shown != key)
        // Anything that is not a 32-byte key has no bech32 form, so it is shown as it is
        // rather than not at all.
        #expect(ProfileSheetView.displayKey(for: "not-a-key") == "not-a-key")
        #expect(ProfileSheetView.middleTruncated("short") == "short")
    }
}
