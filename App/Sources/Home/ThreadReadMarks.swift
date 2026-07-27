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
/// A thread counts as unseen again the moment a reply lands past that mark, which is what
/// makes the count self-correcting rather than a dismissal.
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
    /// `latestReplyAt` is the newest reply in the thread, the reader's own included — so a
    /// thread the reader replied in last is settled by the mark their own reply set.
    func hasUnseen(_ rootID: String, latestReplyAt: Int64) -> Bool {
        latestReplyAt > marks[rootID] ?? 0
    }

    /// The Threads card's number: unread threads the store found, less the ones already
    /// read on this device.
    func unseenCount(among threads: [UnreadThread]) -> Int {
        threads.count { hasUnseen($0.rootID, latestReplyAt: $0.latestReplyAt) }
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
