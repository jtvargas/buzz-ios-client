import BuzzKit
import Foundation
import Observation
import SwiftUI

/// How far the reader has seen into each thread, on this device.
///
/// # Why this is not read state
///
/// NIP-RS keys read state by *channel*. A thread has no context of its own in it, so the
/// only frontier a thread could advance is its channel's — and advancing that would mark
/// every message in the channel read, on every device the account is signed in to, for the
/// crime of opening one thread. There is no finer shared marker to reach for, so "I have
/// seen this thread" is held here instead: local, private, and only ever *subtractive* —
/// it can strike a thread off the Threads count, never add one.
///
/// That is also exactly what JT asked for ("all this is a logic in client"), and it is the
/// same custody argument as ``StarredConversations``: a statement about how one person uses
/// one phone, of no use to anybody else and nothing a relay should be told.
///
/// # What a mark means
///
/// The `created_at` of the newest reply the reader had on screen. Grow-only, so replies
/// arriving while the thread is open advance it and an older snapshot cannot walk it back.
/// A thread counts as unseen again the moment *somebody else's* reply lands past that mark,
/// which is what makes the count self-correcting rather than a dismissal. Whose reply it is
/// matters as much as when it arrived: see ``hasUnseen(_:latestReplyByOthersAt:)``.
@MainActor
@Observable
final class ThreadReadMarks {
    /// Root event id → the newest reply timestamp seen in it.
    private(set) var marks: [String: Int64] = [:]

    /// The `UserDefaults` key behind the marks.
    ///
    /// Pinned by a test, like the star and expansion keys: renaming it silently resurfaces
    /// every thread an existing install has already read, and nothing else would catch it.
    static let storageKey = "threads.readMarks"

    /// How many threads are remembered.
    ///
    /// A cap rather than a sweep, because there is nothing to sweep against: a mark's
    /// thread may be pruned from the store, may never be replied to again, or may be
    /// answered a year later. Keeping the most recently active few hundred bounds the
    /// defaults blob at a few tens of kilobytes; the ones that fall off are threads whose
    /// newest reply is older than three hundred others', and a thread that old resurfacing
    /// as unseen is the harmless direction to be wrong in.
    nonisolated static let capacity = 300

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Values are read one at a time rather than through a whole-dictionary cast: a
        // single malformed entry (a defaults blob written by some future version) then
        // costs that entry instead of every mark on the device.
        let stored = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        marks = stored.compactMapValues { value in
            (value as? NSNumber).map { Int64(truncating: $0) }
        }
    }

    /// Records that everything up to `timestamp` has been seen in this thread. Grow-only,
    /// and persisted immediately — there is no later moment at which reading a thread is
    /// committed.
    func mark(_ rootID: String, seenUpTo timestamp: Int64) {
        guard !rootID.isEmpty, timestamp > 0, timestamp > marks[rootID] ?? 0 else { return }
        marks[rootID] = timestamp
        marks = Self.pruned(marks)
        defaults.set(marks.mapValues(NSNumber.init(value:)), forKey: Self.storageKey)
    }

    /// Whether this thread still holds something the reader has not seen on this device.
    ///
    /// # Why the argument is the newest reply *by somebody else*
    ///
    /// A mark is written from the newest reply that was on screen, which is very often the
    /// reader's own — reply in a thread and the row you just sent is the row that moves the
    /// mark. That makes the mark and the newest reply overall the *same event* seen from two
    /// sides, so comparing one against the other only works while the two stay in step. They
    /// come apart the moment a reply of the reader's lands somewhere the mark cannot follow
    /// it: read the thread on the phone (mark ← the peer's reply), answer it from the
    /// desktop, and the newest reply overall now outruns the phone's mark by a message the
    /// reader wrote themselves. The thread reappears under Threads, on their own words, and
    /// the only way to clear it is to open something they have already read.
    ///
    /// So the comparison is against the last thing somebody *else* said. Nothing the reader
    /// writes can push a thread back into the count, from any device, which is the same rule
    /// the store's own `new_count` has always applied to replies — this makes the device's
    /// half of the arithmetic agree with the relay's half instead of quietly contradicting it.
    ///
    /// - Parameter latestReplyByOthersAt: the newest reply written by anybody but the reader,
    ///   or `nil` when there is no such reply. `nil` is never unseen: a thread the reader
    ///   alone has spoken in holds nothing they can be behind on.
    func hasUnseen(_ rootID: String, latestReplyByOthersAt: Int64?) -> Bool {
        guard let latestReplyByOthersAt else { return false }
        return latestReplyByOthersAt > marks[rootID] ?? 0
    }

    /// The Threads card's number: unread threads the store found, less the ones already
    /// read on this device.
    func unseenCount(among threads: [UnreadThread]) -> Int {
        threads.count { hasUnseen($0.rootID, latestReplyByOthersAt: $0.latestReplyByOthersAt) }
    }

    /// `marks` trimmed to ``capacity``, keeping the most recently active threads.
    ///
    /// Static, pure and `nonisolated` so the trimming rule is tested directly rather than by
    /// writing three hundred entries through a defaults suite.
    nonisolated static func pruned(_ marks: [String: Int64]) -> [String: Int64] {
        guard marks.count > capacity else { return marks }
        // Ties broken on the id so the survivors are a function of the input and not of
        // dictionary order — otherwise which marks are kept differs run to run.
        let kept = marks.sorted { left, right in
            left.value == right.value ? left.key > right.key : left.value > right.value
        }
        .prefix(capacity)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

extension EnvironmentValues {
    /// The device's thread read marks, injected at the sidebar — the one place above both
    /// the Threads screen that reads them and the thread view that writes them.
    ///
    /// Optional, and `nil` by default, so a surface reached without them (the conversation
    /// fixture host) simply records nothing rather than writing marks into the real
    /// defaults suite from a test.
    @Entry var threadReadMarks: ThreadReadMarks?
}
