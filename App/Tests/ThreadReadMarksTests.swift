@testable import Hive
import Foundation
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

        #expect(marks.hasUnseen("root", latestReplyAt: 100))
        marks.mark("root", seenUpTo: 100)
        #expect(!marks.hasUnseen("root", latestReplyAt: 100))
        #expect(marks.hasUnseen("root", latestReplyAt: 101))

        // An older snapshot — a thread re-rendered from a page that has not caught up —
        // must not walk the mark back and resurface a thread the reader has read.
        marks.mark("root", seenUpTo: 50)
        #expect(!marks.hasUnseen("root", latestReplyAt: 100))
        // Neither an empty id nor a zero timestamp is a mark.
        marks.mark("", seenUpTo: 10)
        marks.mark("other", seenUpTo: 0)
        #expect(marks.marks == ["root": 100])

        // Re-read from the same defaults: a relaunch does not resurface a read thread.
        #expect(!ThreadReadMarks(defaults: defaults).hasUnseen("root", latestReplyAt: 100))
        // Pinned: renaming it silently resurfaces every thread an install has read.
        #expect(ThreadReadMarks.storageKey == "threads.readMarks")
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
