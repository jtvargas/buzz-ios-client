import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing
import UIKit

/// Part 6's home shortcuts and the Threads screen behind one of them: what the cards say,
/// how a thread summarises itself, and that the count is live.
@Suite("Home shortcuts", .timeLimit(.minutes(1)))
struct HomeShortcutTests {
    // MARK: - The cards

    @Test("Threads shows a count only when there is something new; Later always says zero")
    func countVisibility() {
        // The shortcut answers "is there anything for me in there". `Threads · 0` is that
        // question answered "no" in a way someone has to read and dismiss every launch.
        #expect(!HomeShortcut.threads.showsCount(0))
        #expect(HomeShortcut.threads.showsCount(1))
        // Later is different only because `Later · 0 items` is what was asked for, and it
        // is currently the only thing that row says about itself.
        #expect(HomeShortcut.later.showsCount(0))

        #expect(HomeShortcut.threads.countLabel(1) == "1 new")
        #expect(HomeShortcut.threads.countLabel(4) == "4 new")
        #expect(HomeShortcut.later.countLabel(0) == "0 items")
        #expect(HomeShortcut.later.countLabel(1) == "1 item")
    }

    @Test("the spoken label drops the interpunct rather than reading it out")
    func accessibilityLabels() {
        #expect(HomeShortcutRow.accessibilityLabel(.threads, count: nil) == "Threads")
        #expect(HomeShortcutRow.accessibilityLabel(.threads, count: 3) == "Threads, 3 new")
        #expect(HomeShortcutRow.accessibilityLabel(.later, count: 0) == "Later, 0 items")
        // The visual join is a middle dot; spoken it is noise.
        #expect(!HomeShortcutRow.accessibilityLabel(.later, count: 0).contains("\u{00B7}"))
        #expect(HomeShortcutRow.separator.contains("\u{00B7}"))
    }

    @Test("both shortcuts name a symbol the system actually has")
    func symbolsExist() {
        // A missing symbol name renders as nothing at all, silently — the same trap
        // ``ThreadView/threadSymbol`` is pinned against.
        for shortcut in HomeShortcut.allCases {
            #expect(UIImage(systemName: shortcut.symbol) != nil, "\(shortcut.symbol) is missing")
        }
    }

    // MARK: - Summarising a thread

    @Test("the opener is cut at 2,000 characters, and marked where it was cut")
    func openerCap() {
        let short = String(repeating: "a", count: 1999)
        #expect(ThreadSummary.opener(short) == short)

        let exact = String(repeating: "a", count: 2000)
        // At the limit, not over it: nothing is cut and nothing is claimed to be.
        #expect(ThreadSummary.opener(exact) == exact)

        let long = String(repeating: "a", count: 2001)
        let cut = ThreadSummary.opener(long)
        #expect(cut.count == 2001)
        #expect(cut.hasSuffix("\u{2026}"))
        #expect(cut.dropLast() == String(repeating: "a", count: 2000))

        // Counted in characters, so a grapheme cluster is never cut in half. 2,001
        // family emoji are far more than 2,000 UTF-16 units; a unit-based cut would land
        // mid-cluster and produce mojibake.
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 2001)
        #expect(ThreadSummary.opener(emoji).count == 2001)
        #expect(ThreadSummary.opener(emoji).dropLast().allSatisfy { $0 == "👩‍👩‍👧‍👦" })
    }

    @Test("a row admits only to the replies it is not showing")
    func moreRepliesCount() {
        // The newest reply is drawn in full, so it is never part of "more".
        #expect(ThreadSummary.moreReplies(activity(replyCount: 1)) == nil)
        #expect(ThreadSummary.moreReplies(activity(replyCount: 2)) == "1 more reply")
        #expect(ThreadSummary.moreReplies(activity(replyCount: 4)) == "3 more replies")
    }

    // MARK: - Live count

    @Test("the Threads count is live and counts threads rather than replies")
    @MainActor
    func threadCountIsLive() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        let opener = try peer.message("question", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
        ], phase: .backfill)
        await waitUntil { model.hasLoaded }
        #expect(model.newThreadCount == 0)

        // Two replies in one thread is one thread to catch up on, not two.
        _ = try await store.ingest(batch: [
            try peer.event(
                .channelMessage, "one",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
            try peer.event(
                .channelMessage, "two",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 3_000
            ),
        ], phase: .live)
        await waitUntil { model.newThreadCount == 1 }

        // Reading the channel to its end clears its threads too — there is no per-thread
        // read state to advance, so this is the honest behaviour rather than a bug.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["general": 3_000],
            sourceCreatedAt: 10, sourceEventID: "e"
        )
        await waitUntil { model.newThreadCount == 0 }
    }

    @Test("the Threads screen reads a thread's two ends and their mentions")
    @MainActor
    func threadsModelLoads() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let model = ThreadsModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        let opener = try peer.message("what do we do", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try peer.event(
                .channelMessage, "middle",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
            try peer.event(
                .channelMessage, "ask @reader",
                tags: [["h", "general"], ["e", opener.id, "", "reply"], ["p", reader.pubkey]],
                at: 3_000
            ),
        ], phase: .backfill)

        await waitUntil { model.threads.count == 1 }
        let thread = try #require(model.threads.first)
        #expect(thread.opener.content == "what do we do")
        #expect(thread.latestReply.content == "ask @reader")
        #expect(thread.intermediateReplyCount == 1)
        #expect(thread.newReplyCount == 2)
        // The reply's own `p` tags, so its `@`-token resolves here exactly as it does in
        // the thread this row opens.
        #expect(model.mentions(for: thread.latestReply.id).map(\.pubkey) == [reader.pubkey])
        #expect(model.mentions(for: thread.opener.id).isEmpty)
    }

    // MARK: - Where a thread lands

    @Test("a thread reached from a message opens at its newest reply; from Threads, at its opener")
    func threadRouteAnchor() {
        // The default is the one the channel timeline has always had, so pushing a thread
        // from a message is unchanged by this part.
        #expect(ThreadRoute(root: "r", channel: "c").anchor == .latestReply)
        #expect(ThreadRoute(root: "r", channel: "c", anchor: .opener).anchor == .opener)
        // Identity is the root alone: the same thread pushed with a different anchor is
        // still the same destination, and must not stack on itself.
        #expect(ThreadRoute(root: "r", channel: "c", anchor: .opener).id
            == ThreadRoute(root: "r", channel: "c").id)
    }

    @Test("landing on the opener asks the scaffold to scroll to it, once it is loaded")
    @MainActor
    func landOnOpener() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let peer = try Fixture()
        let opener = try peer.message("root", in: "general", at: 1_000)

        let model = ThreadModel(
            root: opener.id,
            channel: "general",
            store: store,
            sender: StubSender(),
            // Nothing to fetch: the rows this test lands on are ingested directly below.
            opener: StubThreadOpener(store: store, events: []),
            selfPubkey: nil
        )

        // Nothing loaded yet: there is no row to land on, so nothing is asked for and the
        // thread rests where it would have anyway.
        let before = model.jumpToken
        model.landOnOpener()
        #expect(model.jumpToken == before)

        _ = try await store.ingest(batch: [
            try peer.channelMetadata("general", name: "General", at: 500),
            opener,
            try peer.event(
                .channelMessage, "a reply",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
        ], phase: .backfill)
        model.primeIfNeeded()
        #expect(model.rows.count == 2)

        model.landOnOpener()
        #expect(model.jumpToken == before + 1)
        #expect(model.jumpTarget == .message(opener.id))
    }
}

private extension HomeShortcutTests {
    func activity(replyCount: Int) -> ThreadActivity {
        ThreadActivity(
            rootID: "root",
            channelID: "general",
            opener: row("root", at: 1_000),
            latestReply: row("newest", at: 9_000),
            replyCount: replyCount,
            newReplyCount: 0
        )
    }

    func row(_ id: String, at createdAt: Int64) -> TimelineRow {
        TimelineRow(
            id: id,
            pubkey: String(repeating: "aa", count: 32),
            createdAt: createdAt,
            content: id,
            isEdited: false,
            isDeleted: false,
            richContent: nil,
            delivery: .sent,
            authorName: nil,
            authorPicture: nil,
            parentID: nil,
            rootID: nil,
            replyCount: 0,
            lastReplyAt: nil
        )
    }
}
