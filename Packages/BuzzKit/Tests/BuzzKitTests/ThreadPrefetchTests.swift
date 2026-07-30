@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Which threads a bounded prefetch goes and fetches, and — the part that matters — which
/// ones it stops asking about.
///
/// # The defect these exist to prevent
///
/// The Threads screen renders a thread's newest reply and the faces of whoever is in it,
/// and no relay tally can supply either: only replies can. A channel window never carries
/// replies (`top_level: true` is what NIP-CW is for), so on a cold launch the screen is
/// empty until something fetches them — but "fetch them all" is precisely the unbounded
/// cost NIP-CW exists to avoid. So the fetch is narrowed to the most recently active
/// threads, and its candidate test is "the relay knows about a reply newer than anything I
/// hold".
///
/// That test can become permanently unanswerable. ``BuzzProjector`` writes no `thread` row
/// for a reply carrying no NIP-10 `reply` marker — deliberately, so a channel timeline can
/// exclude replies with one `NOT EXISTS` — while the relay counts that reply and stamps
/// `last_reply_at` from it. Local can then never rise to meet the summary, the candidate
/// test stays true however often it is asked, and since `.ready` re-walks every channel the
/// same fetch is reissued on every reconnect for the life of the process. `thread_prefetch`
/// is the floor under it, and `anUnreadableReplyIsAskedAboutOnlyOnce` is the test that
/// proves the floor holds — it fails without the table.
@Suite("Thread prefetch candidates", .timeLimit(.minutes(1)))
struct ThreadPrefetchTests {
    private static let channel = "room-1"

    private func summary(
        for root: String,
        descendantCount: Int,
        lastReplyAt: Int64?,
        in channel: String = ThreadPrefetchTests.channel,
        from relay: Fixture,
        at seconds: Int64 = 1_700_000_500
    ) throws -> NostrEvent {
        let last = lastReplyAt.map(String.init) ?? "null"
        let content = """
        {"reply_count":\(descendantCount),"descendant_count":\(descendantCount),\
        "last_reply_at":\(last),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", channel]], at: seconds
        )
    }

    private func reply(
        _ author: Fixture,
        _ content: String,
        to root: NostrEvent,
        in channel: String = ThreadPrefetchTests.channel,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, content,
            tags: [["h", channel], ["e", root.id, "", "reply"]], at: seconds
        )
    }

    /// A reply this device cannot place: it names its parent with a bare `e` tag and no
    /// marker, so ``NostrEvent/threadReference`` resolves neither parent nor root and the
    /// projector writes no `thread` row. The relay, which does not share our marker
    /// conventions, counts it regardless.
    private func unmarkedReply(
        _ author: Fixture,
        _ content: String,
        to root: NostrEvent,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, content,
            tags: [["h", Self.channel], ["e", root.id]], at: seconds
        )
    }

    private func candidates(_ store: BuzzEventStore, channel: String? = nil) throws -> [ThreadPrefetchCandidate] {
        try store.threadPrefetchCandidates(channel: channel, limit: 20)
    }

    // MARK: - What is asked for

    @Test("a thread whose newest reply this device does not hold is fetched")
    func aThreadBehindTheRelayIsACandidate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        // The cold-launch shape: the page row and its tally, no replies.
        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            root,
            try summary(for: root.id, descendantCount: 3, lastReplyAt: 1_400, from: relay),
        ], phase: .backfill)

        let found = try candidates(store)
        #expect(found.count == 1)
        #expect(found.first?.rootID == root.id)
        #expect(found.first?.channelID == Self.channel)
    }

    @Test("a thread with no relay tally is never fetched")
    func silenceIsNotACandidate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        #expect(try candidates(store).isEmpty)
    }

    /// A tally whose `last_reply_at` is `null` — every reply withdrawn — describes no reply
    /// to go and get.
    @Test("a thread whose replies were all withdrawn is not fetched")
    func aWithdrawnThreadIsNotACandidate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            root,
            try summary(for: root.id, descendantCount: 0, lastReplyAt: nil, from: relay),
        ], phase: .backfill)

        #expect(try candidates(store).isEmpty)
    }

    /// The join to `event` is a guard as well as how the channel is resolved: a thread whose
    /// opener is absent cannot render on the screen this prefetch feeds, so fetching its
    /// replies would spend a request on rows nothing can draw.
    @Test("a thread whose opener this device does not hold is not fetched")
    func anAbsentRootIsNotACandidate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(
            batch: [try summary(for: "a-root-nobody-has", descendantCount: 2, lastReplyAt: 1_400, from: relay)],
            phase: .backfill
        )

        #expect(try candidates(store).isEmpty)
    }

    // MARK: - Convergence

    /// The property that makes the predicate safe to re-ask on every arrival: a successful
    /// fetch answers it. Local `MAX(created_at)` rises to exactly the `last_reply_at` it was
    /// measured against, so the row settles — a partially held thread is a *resting* state,
    /// not a pending one.
    @Test("a thread stops being fetched once its newest reply is held")
    func holdingTheNewestReplySettlesTheThread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            root,
            // Thirty replies deep, of which this device is about to hold only the newest.
            try summary(for: root.id, descendantCount: 30, lastReplyAt: 1_400, from: relay),
        ], phase: .backfill)
        #expect(try candidates(store).count == 1)

        _ = try await store.ingest(
            batch: [try reply(author, "the newest one", to: root, at: 1_400)], phase: .backfill
        )

        // Still holding 1 of 30 — and deliberately no longer a candidate. Asking again
        // would fetch the same page forever.
        #expect(try candidates(store).isEmpty)
    }

    @Test("a thread is fetched again when it gains a reply")
    func newActivityReopensAThread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            root,
            try summary(for: root.id, descendantCount: 1, lastReplyAt: 1_400, from: relay),
            try reply(author, "held", to: root, at: 1_400),
        ], phase: .backfill)
        #expect(try candidates(store).isEmpty)

        // A fresh tally: a later event id, a later `last_reply_at`.
        _ = try await store.ingest(
            batch: [try summary(
                for: root.id, descendantCount: 2, lastReplyAt: 1_500, from: relay, at: 1_700_000_600
            )],
            phase: .live
        )

        #expect(try candidates(store).count == 1)
    }

    // MARK: - The brake

    /// The loop this table exists to break, driven from the failing side.
    ///
    /// The reply is real and the relay counts it, but it carries no `reply` marker so this
    /// device can never hold it as a `thread` row — `local MAX(created_at)` stays below
    /// `last_reply_at` no matter how many times the thread is fetched. Without the recorded
    /// attempt this thread is a candidate on every pass, for the life of the process, in
    /// every channel that holds one such reply. With it, it costs one fetch per tally.
    @Test("a reply this device cannot place is asked about once, not forever")
    func anUnreadableReplyIsAskedAboutOnlyOnce() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let tally = try summary(for: root.id, descendantCount: 1, lastReplyAt: 1_400, from: relay)
        _ = try await store.ingest(batch: [
            root,
            tally,
            try unmarkedReply(author, "counted by the relay, invisible here", to: root, at: 1_400),
        ], phase: .backfill)

        // The premise: the reply is in the log and is *not* a thread row, so the predicate
        // is true and stays true however the fetch goes.
        #expect(try await store.rowCount("thread") == 0)
        let first = try candidates(store)
        #expect(first.count == 1)
        #expect(first.first?.summaryEventID == tally.id)

        // A fetch that returns it, ingests it, and changes nothing — then records the
        // attempt, which is the only thing that can settle this thread.
        try await store.recordThreadPrefetch(root: root.id, summaryEventID: tally.id)

        #expect(try candidates(store).isEmpty)
    }

    /// The brake must not be a mute button: a *new* tally is a new question.
    @Test("a recorded attempt is superseded by a fresh tally")
    func aFreshTallyIsAskedAboutAgain() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let first = try summary(for: root.id, descendantCount: 1, lastReplyAt: 1_400, from: relay)
        _ = try await store.ingest(batch: [root, first], phase: .backfill)
        try await store.recordThreadPrefetch(root: root.id, summaryEventID: first.id)
        #expect(try candidates(store).isEmpty)

        let second = try summary(
            for: root.id, descendantCount: 2, lastReplyAt: 1_500, from: relay, at: 1_700_000_600
        )
        _ = try await store.ingest(batch: [second], phase: .live)

        let found = try candidates(store)
        #expect(found.count == 1)
        #expect(found.first?.summaryEventID == second.id)
    }

    /// Recording against a summary that has since been replaced must not swallow the
    /// replacement. The engine passes the id it *selected* against for exactly this reason.
    @Test("recording a stale tally leaves the thread candidate")
    func recordingAStaleTallyDoesNotSuppressTheNewOne() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let first = try summary(for: root.id, descendantCount: 1, lastReplyAt: 1_400, from: relay)
        let second = try summary(
            for: root.id, descendantCount: 2, lastReplyAt: 1_500, from: relay, at: 1_700_000_600
        )
        _ = try await store.ingest(batch: [root, first, second], phase: .backfill)

        // A fetch that began while `first` was current, finishing after `second` arrived.
        try await store.recordThreadPrefetch(root: root.id, summaryEventID: first.id)

        #expect(try candidates(store).count == 1)
    }

    @Test("a channel's fetch reaches only that channel's threads")
    func channelScopeHolds() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let here = try author.message("here", in: Self.channel, at: 1_000)
        let elsewhere = try author.message("elsewhere", in: "room-2", at: 1_000)
        _ = try await store.ingest(batch: [
            here,
            elsewhere,
            try summary(for: here.id, descendantCount: 1, lastReplyAt: 1_400, from: relay),
            try summary(for: elsewhere.id, descendantCount: 1, lastReplyAt: 1_500, in: "room-2", from: relay),
        ], phase: .backfill)

        #expect(try candidates(store).count == 2)
        #expect(try candidates(store, channel: Self.channel).map(\.rootID) == [here.id])
        #expect(try candidates(store, channel: "room-2").map(\.rootID) == [elsewhere.id])
    }

    /// The bound is "the most recently active", so the order is what makes the limit mean
    /// something — a limit over an arbitrary order would fetch an arbitrary twenty.
    @Test("the busiest threads are fetched first")
    func mostRecentActivityComesFirst() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let old = try author.message("old", in: Self.channel, at: 1_000)
        let middle = try author.message("middle", in: Self.channel, at: 1_001)
        let recent = try author.message("recent", in: Self.channel, at: 1_002)
        _ = try await store.ingest(batch: [
            old, middle, recent,
            try summary(for: old.id, descendantCount: 1, lastReplyAt: 1_100, from: relay),
            try summary(for: middle.id, descendantCount: 1, lastReplyAt: 1_200, from: relay),
            try summary(for: recent.id, descendantCount: 1, lastReplyAt: 1_300, from: relay),
        ], phase: .backfill)

        #expect(try store.threadPrefetchCandidates(channel: nil, limit: 20).map(\.rootID)
            == [recent.id, middle.id, old.id])
        #expect(try store.threadPrefetchCandidates(channel: nil, limit: 2).map(\.rootID)
            == [recent.id, middle.id])
    }

}

/// That the prefetch's record and a thread fetch's record are not the same claim.
///
/// `thread_prefetch` says *asked about*; `thread_fetch` says *hold in full*, and only the
/// second suppresses the relay's tally. A bounded prefetch may make the first and must never
/// make the second — one table doing both jobs would mean a thread of thirty replies
/// advertising the twenty this device happens to hold, which is the understating half of the
/// bug Part A fixed.
@Suite("A prefetch attempt is not a claim of completeness", .timeLimit(.minutes(1)))
struct ThreadPrefetchClaimTests {
    private static let channel = "room-1"

    @Test("recording an attempt does not make the local count authoritative")
    func anAttemptIsNotAClaimOfCompleteness() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let content = """
        {"reply_count":30,"descendant_count":30,"last_reply_at":1400,"participants":[]}
        """
        _ = try await store.ingest(batch: [
            root,
            try relay.event(
                .threadSummary, content,
                tags: [["e", root.id], ["d", root.id], ["h", Self.channel]], at: 1_700_000_500
            ),
            try author.event(
                .channelMessage, "one of thirty",
                tags: [["h", Self.channel], ["e", root.id, "", "reply"]], at: 1_400
            ),
        ], phase: .backfill)
        try await store.recordThreadPrefetch(root: root.id, summaryEventID: nil)

        let row = try #require(try store.timeline(channel: Self.channel).first)
        #expect(row.replyCount == 30)
    }
}
