import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing

/// The device-local record of how far a reader has got in each thread — what makes the
/// Threads count clear when a thread is opened, without touching the channel's shared
/// NIP-RS frontier.
@Suite("Thread read marks", .timeLimit(.minutes(1)))
struct ThreadReadMarksTests {
    @Test("a mark only ever moves forward, and is remembered across launches")
    @MainActor
    func marksAreGrowOnlyAndPersisted() throws {
        let suiteName = "thread-marks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let marks = ThreadReadMarks(defaults: defaults)

        #expect(marks.hasUnseen("root", latestReplyByOthersAt: 100))
        marks.mark("root", seenUpTo: 100)
        #expect(!marks.hasUnseen("root", latestReplyByOthersAt: 100))
        #expect(marks.hasUnseen("root", latestReplyByOthersAt: 101))

        // Nobody else has spoken in it at all: there is no timestamp to be behind, marked
        // or not, so the question is answered without consulting the mark.
        #expect(!marks.hasUnseen("root", latestReplyByOthersAt: nil))
        #expect(!marks.hasUnseen("never-marked", latestReplyByOthersAt: nil))

        // An older snapshot — a thread re-rendered from a page that has not caught up —
        // must not walk the mark back and resurface a thread the reader has read.
        marks.mark("root", seenUpTo: 50)
        #expect(!marks.hasUnseen("root", latestReplyByOthersAt: 100))
        // Neither an empty id nor a zero timestamp is a mark.
        marks.mark("", seenUpTo: 10)
        marks.mark("other", seenUpTo: 0)
        #expect(marks.marks == ["root": 100])

        // Re-read from the same defaults: a relaunch does not resurface a read thread.
        #expect(!ThreadReadMarks(defaults: defaults).hasUnseen("root", latestReplyByOthersAt: 100))
        // Pinned: renaming it silently resurfaces every thread an install has read.
        #expect(ThreadReadMarks.storageKey == "threads.readMarks")
    }

    /// The cross-device case the count is judged by somebody else's reply for.
    ///
    /// Everything here is ordinary: a thread read on the phone, answered from the desktop.
    /// The reply arrives over the relay like any other, lands past the mark this device
    /// wrote, and is the newest thing in the thread — so a count that looks at the newest
    /// reply overall puts the thread back on the card, on the strength of a message the
    /// reader wrote themselves and has by definition already seen. Nothing about it is
    /// visible from either side alone: the store is right that the thread is unread, the
    /// mark is right about how far this device got, and only the comparison between them
    /// is wrong.
    @Test("a reply of the reader's own, sent from another device, does not resurface a thread")
    @MainActor
    func ownReplyFromAnotherDeviceDoesNotResurface() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let suiteName = "thread-marks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let marks = ThreadReadMarks(defaults: defaults)

        let opener = try peer.message("question", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try peer.event(
                .channelMessage, "an answer",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
        ], phase: .backfill)

        var threads = try store.unreadThreads(selfPubkey: reader.pubkey)
        #expect(marks.unseenCount(among: threads) == 1)

        // Read here, on the phone: the mark takes the newest row that was on screen.
        marks.mark(opener.id, seenUpTo: 2_000)
        #expect(marks.unseenCount(among: threads) == 0)

        // Now the reader answers the same thread from the desktop. It comes back down as an
        // ordinary reply: newer than the mark this device set, and newer than everything
        // else in the thread.
        _ = try await store.ingest(batch: [
            try reader.event(
                .channelMessage, "answering from my laptop",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 3_000
            ),
        ], phase: .live)

        threads = try store.unreadThreads(selfPubkey: reader.pubkey)
        // The store still reports the thread as unread — the peer's reply is still past the
        // channel's frontier, and this device's mark is no business of the relay's. What
        // moved is the newest reply, and it moved because of something the reader wrote.
        #expect(threads.first?.newReplyCount == 1)
        #expect(threads.first?.latestReplyAt == 3_000)
        // So the card stays clear. Comparing the mark against `latestReplyAt` is what puts
        // `Threads · 1` back for a thread the reader has read, on their own message.
        #expect(marks.unseenCount(among: threads) == 0)

        // And the mark is still a mark, not a dismissal: somebody else speaking brings the
        // thread straight back, with nothing to undo.
        _ = try await store.ingest(batch: [
            try peer.event(
                .channelMessage, "one more thing",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 4_000
            ),
        ], phase: .live)
        threads = try store.unreadThreads(selfPubkey: reader.pubkey)
        #expect(marks.unseenCount(among: threads) == 1)
    }

    /// The Threads screen's **Mark As Read** button, exercised end to end: the same store
    /// read that feeds the row, the same mark the row's button writes, and the same
    /// assertion the open path is already held to — nothing published, only this device's
    /// mark moved.
    @Test("Mark As Read clears a thread in place, without touching the channel's shared frontier")
    @MainActor
    func markAsReadClearsWithoutOpening() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let asker = try Fixture()
        let answerer = try Fixture()
        let reader = try Fixture()

        let suiteName = "thread-marks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let marks = ThreadReadMarks(defaults: defaults)

        let model = ThreadsModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        let opener = try asker.message("question", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try answerer.event(
                .channelMessage, "an answer",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
        ], phase: .backfill)

        await waitUntil { model.threads.count == 1 }
        let thread = try #require(model.threads.first)
        #expect(thread.hasNewReplies)
        #expect(marks.hasUnseen(thread.rootID, latestReplyByOthersAt: thread.latestReplyByOthersAt))

        // What the button does: mark straight to the newest reply's own timestamp, the
        // same call `ThreadView`'s open path makes once it has scrolled to the bottom —
        // without opening the thread and without publishing anything.
        marks.mark(thread.rootID, seenUpTo: thread.latestReply.createdAt)
        #expect(!marks.hasUnseen(thread.rootID, latestReplyByOthersAt: thread.latestReplyByOthersAt))

        // The store still reports the reply as new — nothing was published, exactly like
        // the open path: only this device's mark moved.
        let stillUnread = try store.unreadThreads(selfPubkey: reader.pubkey)
        #expect(stillUnread.first?.newReplyCount == 1)
    }

    @Test("the marks are bounded, keeping the most recently active threads")
    func marksArePruned() {
        let capacity = ThreadReadMarks.capacity
        let marks = Dictionary(
            uniqueKeysWithValues: (0 ..< (capacity + 10)).map { ("root-\($0)", Int64($0 + 1)) }
        )
        let pruned = ThreadReadMarks.pruned(marks)
        #expect(pruned.count == capacity)
        // The ten oldest fell off, and nothing newer did.
        #expect(pruned["root-0"] == nil)
        #expect(pruned["root-9"] == nil)
        #expect(pruned["root-10"] == Int64(11))
        #expect(pruned["root-\(capacity + 9)"] == Int64(capacity + 10))
        // Under the cap nothing is touched, so the common case allocates no order at all.
        #expect(ThreadReadMarks.pruned(["a": 1]) == ["a": 1])
    }
}
