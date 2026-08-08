import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing
import UIKit

/// The home shortcut cards and the Threads screen behind one of them: what a card says, how
/// a thread summarises itself and names its people, and that the count is live — and that it
/// clears when this device has read the thread.
@Suite("Home shortcuts", .timeLimit(.minutes(1)))
struct HomeShortcutTests {
    // MARK: - The cards

    @Test("every card says its number, zero included")
    func countLabels() {
        // Threads used to say nothing at zero, on the reasoning that an absence is quieter
        // than a `0`. It is quieter, and it is also ambiguous: a card with no second line
        // reads as one that has not loaded rather than one with nothing in it.
        #expect(HomeShortcut.threads.countLabel(0) == "0 new")
        #expect(HomeShortcut.threads.countLabel(1) == "1 new")
        #expect(HomeShortcut.threads.countLabel(4) == "4 new")
        #expect(HomeShortcut.later.countLabel(0) == "0 items")
        #expect(HomeShortcut.later.countLabel(1) == "1 item")
    }

    @Test("a card with something in it is drawn in the accent, and an empty one is not")
    func borderFollowsTheCount() {
        // The rule the card picks its border colour from — both cards are bordered, and
        // this is what decides which of them is bordered in the accent. Asserted here
        // rather than against a rendered card, because a stroke is not something a test can
        // read back — and stated as a fact about the *count* so no card is ever the
        // exception.
        #expect(!HomeShortcutCard.hasSomethingWaiting(0))
        #expect(HomeShortcutCard.hasSomethingWaiting(1))
        #expect(HomeShortcutCard.hasSomethingWaiting(12))
    }

    @Test("only the Threads card offers to mark everything read")
    func onlyThreadsOffersMarkAllRead() {
        // The rule the long press is drawn from, stated as a fact about each destination —
        // whether its contents have a read state at all. A `case .threads` in the card view
        // would be a rule a fourth destination silently opts out of, and a menu on Drafts
        // would be an action with nothing to act on.
        // As the whole list rather than card by card: this fails both ways round — if
        // Threads ever stops offering it, and if a new destination quietly starts.
        #expect(HomeShortcut.allCases.filter(\.offersMarkAllRead) == [.threads])
    }

    @Test("a card is spoken as its destination and what is in it")
    func accessibilityLabels() {
        // `.combine` flattens the card into one element, so this string is the whole of
        // what a screen reader gets — the two lines it draws have to arrive as a sentence.
        #expect(HomeShortcutCard.accessibilityLabel(.threads, count: 0) == "Threads, 0 new")
        #expect(HomeShortcutCard.accessibilityLabel(.threads, count: 3) == "Threads, 3 new")
        #expect(HomeShortcutCard.accessibilityLabel(.later, count: 0) == "Later, 0 items")
    }

    @Test("every glyph a card can draw resolves to something")
    func glyphsExist() {
        // A name that resolves to nothing renders as nothing at all, silently — the same trap
        // ``ThreadView/threadSymbol`` is pinned against. Two kinds now, each checked the only
        // way its kind can be: a symbol against the system library, an asset against the
        // bundle. Handing either name to the other call draws a blank card and no error.
        for shortcut in HomeShortcut.allCases {
            for hasItems in [true, false] {
                switch shortcut.glyph(hasItems: hasItems) {
                case let .symbol(name):
                    #expect(UIImage(systemName: name) != nil, "symbol \(name) is missing")
                case let .asset(name):
                    #expect(UIImage(named: name) != nil, "asset \(name) is missing")
                }
            }
        }
    }

    @Test("the card's own artwork is a template, so it takes the card's colour")
    func ownArtworkIsTemplate() {
        // Without this the drawing ships as-drawn — black on a dark card, which is invisible
        // rather than wrong-coloured. One key in `Contents.json`, and nothing at runtime says
        // it is missing.
        let image = UIImage(named: HomeShortcut.threadsGlyph)
        #expect(image != nil)
        #expect(image?.renderingMode == .alwaysTemplate)
    }

    @Test("a card with items draws the .fill cut, and the outline when it is empty")
    func symbolFollowsTheCount() {
        // Empty is always the outline.
        #expect(HomeShortcut.drafts.glyph(hasItems: false) == .symbol("paperplane"))
        #expect(HomeShortcut.later.glyph(hasItems: false) == .symbol("bookmark"))
        // With items, the filled cut — the second signal beside the card's accent edge.
        #expect(HomeShortcut.drafts.glyph(hasItems: true) == .symbol("paperplane.fill"))
        #expect(HomeShortcut.later.glyph(hasItems: true) == .symbol("bookmark.fill"))
        // Threads draws the owner's own artwork, which ships one cut — so it keeps the same
        // drawing either way, exactly as `text.append` did for want of a `.fill` counterpart.
        // The card still says "there is something here" with its accent edge.
        #expect(HomeShortcut.threads.glyph(hasItems: true) == .asset(HomeShortcut.threadsGlyph))
        #expect(HomeShortcut.threads.glyph(hasItems: false) == .asset(HomeShortcut.threadsGlyph))
        #expect(!HomeShortcut.threads.signalsWithGlyph)
    }

    @Test("Drafts counts items, like Later")
    func draftsCountLabel() {
        #expect(HomeShortcut.drafts.countLabel(0) == "0 items")
        #expect(HomeShortcut.drafts.countLabel(1) == "1 item")
        #expect(HomeShortcut.drafts.countLabel(4) == "4 items")
        #expect(HomeShortcutCard.accessibilityLabel(.drafts, count: 2) == "Drafts, 2 items")
    }

    // MARK: - Summarising a thread

    @Test("a shown message is cut at 2,000 characters, and marked where it was cut")
    func messageCap() {
        let short = String(repeating: "a", count: 1999)
        #expect(ThreadSummary.cut(short) == short)

        let exact = String(repeating: "a", count: 2000)
        // At the limit, not over it: nothing is cut and nothing is claimed to be.
        #expect(ThreadSummary.cut(exact) == exact)

        let long = String(repeating: "a", count: 2001)
        let cut = ThreadSummary.cut(long)
        #expect(cut.count == 2001)
        #expect(cut.hasSuffix("\u{2026}"))
        #expect(cut.dropLast() == String(repeating: "a", count: 2000))

        // Counted in characters, so a grapheme cluster is never cut in half. 2,001
        // family emoji are far more than 2,000 UTF-16 units; a unit-based cut would land
        // mid-cluster and produce mojibake.
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 2001)
        #expect(ThreadSummary.cut(emoji).count == 2001)
        #expect(ThreadSummary.cut(emoji).dropLast().allSatisfy { $0 == "👩‍👩‍👧‍👦" })
    }

    @Test("the cut is applied to the row, so a huge opener is never parsed whole")
    func summarisedRowIsCut() {
        let long = String(repeating: "a", count: 2_500)
        let plain = ThreadSummary.summarised(row("root", at: 1_000, content: long))
        #expect(plain.content.count == 2_001)
        #expect(plain.content.hasSuffix("\u{2026}"))

        // The rich body is what renders when there is one, so it is cut too — cutting only
        // the plain one would leave the 2,500 characters that actually reach the parser.
        let rich = ThreadSummary.summarised(
            row("root", at: 1_000, content: long, richContent: long)
        )
        #expect(rich.richContent?.count == 2_001)

        // Nothing else about the message moves, and a message inside the limit is handed
        // back as it came — identity, author, delivery and reply tally are what the row
        // draws its avatar, its name and its replies strip from.
        let short = row("root", at: 1_000, content: "short", replyCount: 4)
        #expect(ThreadSummary.summarised(short) == short)
    }

    @Test("a thread's people are named, then counted")
    func participantSummary() {
        #expect(ThreadParticipantSummary.text(names: []) == nil)
        #expect(ThreadParticipantSummary.text(names: ["Jonathan"]) == "Jonathan")
        #expect(ThreadParticipantSummary.text(names: ["Jonathan", "Jarvis"]) == "Jonathan and Jarvis")
        #expect(ThreadParticipantSummary.text(names: ["Jonathan", "Jarvis", "Lisanne"])
            == "Jonathan, Jarvis, and Lisanne")
        // JT's own example: three names, then a number.
        #expect(ThreadParticipantSummary.text(names: ["Jonathan", "Jarvis", "Lisanne", "Ada", "Bo", "Cy"])
            == "Jonathan, Jarvis, Lisanne, and 3 others")
        #expect(ThreadParticipantSummary.text(names: ["Jonathan", "Jarvis", "Lisanne", "Ada"])
            == "Jonathan, Jarvis, Lisanne, and 1 other")

        // The total is passed separately because the read that produced the names is
        // capped: what is drawn is three names, but what is counted is everybody.
        #expect(ThreadParticipantSummary.text(names: ["Jonathan", "Jarvis", "Lisanne"], total: 9)
            == "Jonathan, Jarvis, Lisanne, and 6 others")
        // A total that disagrees with the names in hand never hides one of them.
        #expect(ThreadParticipantSummary.text(names: ["Jonathan", "Jarvis"], total: 1)
            == "Jonathan and Jarvis")
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

        let suiteName = "thread-marks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        let marks = ThreadReadMarks(defaults: defaults)
        let run = Task { await model.run() }
        defer { run.cancel() }

        // The reader authored the opener, so this thread remains in the
        // participation-scoped unread list while peer replies drive the count.
        let opener = try reader.message("question", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
        ], phase: .backfill)
        await waitUntil { model.hasLoaded }
        #expect(model.unreadThreads.isEmpty)

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
        await waitUntil { model.unreadThreads.count == 1 }
        #expect(model.unreadThreads.first?.newReplyCount == 2)
        #expect(marks.unseenCount(among: model.unreadThreads) == 1)

        // Opening the thread strikes it off the card, on this device, without touching the
        // channel's shared frontier — which is exactly what JT asked for and what NIP-RS
        // cannot express. The store still reports the thread as unread.
        marks.mark(opener.id, seenUpTo: 3_000)
        #expect(model.unreadThreads.count == 1)
        #expect(marks.unseenCount(among: model.unreadThreads) == 0)

        // A newer reply lands past the mark: unread again, with no dismissal to undo.
        _ = try await store.ingest(batch: [
            try peer.event(
                .channelMessage, "three",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 4_000
            ),
        ], phase: .live)
        await waitUntil { model.unreadThreads.first?.latestReplyAt == 4_000 }
        #expect(marks.unseenCount(among: model.unreadThreads) == 1)

        // Reading the channel to its end still clears its threads: the mark subtracts from
        // the store's answer, it does not replace it.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["general": 4_000],
            sourceCreatedAt: 10, sourceEventID: "e"
        )
        await waitUntil { model.unreadThreads.isEmpty }
        #expect(marks.unseenCount(among: model.unreadThreads) == 0)
    }

    @Test("the Threads screen reads each thread's two messages, their mentions, and its people")
    @MainActor
    func threadsModelLoads() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let answerer = try Fixture()
        let reader = try Fixture()

        let model = ThreadsModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        let opener = try reader.event(
            .channelMessage, "what do we do about @reader",
            tags: [["h", "general"], ["p", reader.pubkey]], at: 1_000
        )
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try answerer.event(
                .channelMessage, "middle",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
            try answerer.event(
                .channelMessage, "and again",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 3_000
            ),
        ], phase: .backfill)

        await waitUntil { model.threads.count == 1 }
        let thread = try #require(model.threads.first)
        #expect(thread.opener.content == "what do we do about @reader")
        #expect(thread.latestReply.content == "and again")
        #expect(thread.newReplyCount == 2)
        // The opener's own `p` tags, so its `@`-token resolves here exactly as it does in
        // the thread this row opens. A reply that mentions nobody resolves to nothing, which
        // is not the same as one whose refs were never read — see `ThreadsRowTests`.
        #expect(model.mentions(for: thread.opener.id).map(\.pubkey) == [reader.pubkey])
        #expect(model.mentions(for: thread.latestReply.id).isEmpty)

        // The people in the thread: whoever opened it, then whoever replied — the opener
        // first and exactly once, however many times each of them spoke.
        #expect(model.people(in: thread) == [reader.pubkey, answerer.pubkey])
    }

    @Test("someone who opened a thread and then replied in it is one person, once")
    @MainActor
    func participantsDoNotDuplicateTheOpener() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let asker = try Fixture()

        let model = ThreadsModel(store: store, selfPubkey: nil)
        let run = Task { await model.run() }
        defer { run.cancel() }

        let opener = try asker.message("thinking out loud", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try asker.event(
                .channelMessage, "answering myself",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
        ], phase: .backfill)

        await waitUntil { model.threads.count == 1 }
        let thread = try #require(model.threads.first)
        #expect(model.people(in: thread) == [asker.pubkey])
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
        #expect(model.jumpTarget == .message(opener.id, animated: true))
    }
}

private extension HomeShortcutTests {
    func row(
        _ id: String,
        at createdAt: Int64,
        content: String? = nil,
        richContent: String? = nil,
        replyCount: Int = 0
    ) -> TimelineRow {
        TimelineRow(
            id: id,
            pubkey: String(repeating: "aa", count: 32),
            createdAt: createdAt,
            content: content ?? id,
            isEdited: false,
            isDeleted: false,
            richContent: richContent,
            delivery: .sent,
            authorName: nil,
            authorPicture: nil,
            parentID: nil,
            rootID: nil,
            replyCount: replyCount,
            lastReplyAt: nil
        )
    }
}
