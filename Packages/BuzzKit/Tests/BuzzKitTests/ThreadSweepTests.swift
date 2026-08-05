@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The candidate source that does not read the relay's tally.
///
/// # The defect these pin
///
/// A root behind the sync watermark is never re-paged by the channel window — that query
/// orders by each root's own immutable `created_at` — so its `kind:39005` tally never
/// refreshes. A reply landing on it while the phone is asleep raises `last_reply_at` on the
/// relay and nothing local ever learns it. The prefetch selects on
/// `last_reply_at > local MAX(created_at)`, so a stale tally means the thread is **never a
/// candidate**: the launch pass skips precisely the threads that have fallen behind. That is
/// the "replies never arrive" half of the defect, and the first test below is the one that
/// states it directly — the same root, invisible to one candidate query and visible to this
/// one.
@Suite("Thread sweep candidates", .timeLimit(.minutes(1)))
struct ThreadSweepTests {
    private static let channel = "room"
    private static let horizon: Int64 = 1_000
    private static let staleBefore: Int64 = 9_000

    /// The whole reason this query exists, stated as one assertion against both queries.
    @Test("a root whose tally went stale is invisible to the prefetch and visible here")
    func aStaleTallyHidesTheThreadFromThePrefetchOnly() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        // The device holds the root and one reply. The relay's tally is *stale* — it still
        // describes that same reply — because the root fell behind the watermark before the
        // reply that followed it was ever summarised.
        let root = try fixtures.root(at: 2_000)
        let held = try fixtures.reply(to: root, at: 2_100)
        try await store.ingest(batch: fixtures.channelState + [
            root, held, try fixtures.summary(for: root.id, lastReplyAt: 2_100),
        ], phase: .backfill)

        // `last_reply_at (2100) > MAX(thread.created_at) (2100)` is false, so the prefetch
        // has nothing to offer. This is not a bug in the prefetch — it is the tally lying.
        #expect(try store.threadPrefetchCandidates(channel: nil, limit: 20).isEmpty)

        // The sweep does not ask the tally anything, so the thread is still reachable.
        let candidates = try store.threadSweepCandidates(
            identity: fixtures.identity, horizon: Self.horizon,
            staleBefore: Self.staleBefore, limit: 40
        )
        #expect(candidates.map(\.rootID) == [root.id])
        // And it asks from the newest reply it holds, so an unchanged thread answers empty.
        #expect(candidates.first?.since == 2_100)
        #expect(candidates.first?.channelID == Self.channel)
    }

    /// A thread this device has never seen a reply to asks from the root itself — the case
    /// where the very first reply was the one missed, which no reply-derived `since` could
    /// reach.
    @Test("a thread with no replies held is asked about from the root's own timestamp")
    func sinceFallsBackToTheRoot() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        let root = try fixtures.root(at: 2_000)
        try await store.ingest(batch: fixtures.channelState + [root], phase: .backfill)

        let candidates = try store.threadSweepCandidates(
            identity: fixtures.identity, horizon: Self.horizon,
            staleBefore: Self.staleBefore, limit: 40
        )
        #expect(candidates.map(\.since) == [2_000])
    }

    /// The brake. Without it the sweep re-asks the same roots on every authoritative pass
    /// forever, on a device that is entirely caught up.
    @Test("a root swept at or after the threshold is skipped, and reappears once it moves")
    func aSweptRootIsSkippedUntilTheThresholdMovesPast() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        let root = try fixtures.root(at: 2_000)
        try await store.ingest(batch: fixtures.channelState + [root], phase: .backfill)
        try await store.recordThreadSweep(roots: [root.id], at: 5_000)

        // Swept exactly at the threshold counts as swept: the engine passes the moment the
        // socket became ready, and a sweep performed on that socket must not re-arm itself
        // within the same pass.
        #expect(try Self.candidates(store, fixtures, staleBefore: 5_000).isEmpty)
        #expect(try Self.candidates(store, fixtures, staleBefore: 4_999).isEmpty)
        // A later socket moves the threshold past it and the root is offered again.
        #expect(try Self.candidates(store, fixtures, staleBefore: 5_001).map(\.rootID) == [root.id])
    }

    /// What makes the per-pass cap a throughput knob rather than a coverage ceiling. Ordered
    /// by recency alone, the same capful would be re-served on every launch and everything
    /// behind it would go permanently unswept — the same blind spot the sweep exists to
    /// close.
    @Test("candidates come back never-swept first, then least-recently-swept")
    func candidatesRotateLeastRecentlySweptFirst() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        // Deliberately adversarial: the never-swept root is the *oldest*, so a recency
        // ordering would put it last rather than first.
        let fresh = try fixtures.root(at: 3_000)
        let sweptLate = try fixtures.root(at: 2_500)
        let neverSwept = try fixtures.root(at: 2_000)
        try await store.ingest(
            batch: fixtures.channelState + [fresh, sweptLate, neverSwept], phase: .backfill
        )
        try await store.recordThreadSweep(roots: [fresh.id], at: 4_000)
        try await store.recordThreadSweep(roots: [sweptLate.id], at: 3_000)

        let candidates = try Self.candidates(store, fixtures, staleBefore: 5_000)
        #expect(candidates.map(\.rootID) == [neverSwept.id, sweptLate.id, fresh.id])
    }

    @Test("the horizon and channel membership bound what may be asked about")
    func membershipAndHorizonBoundTheCandidates() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        let inside = try fixtures.root(at: 2_000)
        let tooOld = try fixtures.root(at: 999)
        let elsewhere = try fixtures.root(at: 2_000, in: "not-joined")
        try await store.ingest(batch: fixtures.channelState + [
            inside, tooOld, elsewhere,
            // The unjoined channel exists and is known; what it lacks is this identity on
            // its roster, which is the only thing keeping it out.
            try fixtures.relay.event(.groupMetadata, "", tags: [["d", "not-joined"], ["name", "Other"]]),
        ], phase: .backfill)

        #expect(try Self.candidates(store, fixtures, staleBefore: Self.staleBefore)
            .map(\.rootID) == [inside.id])
    }

    /// Asking about a reply's `e` tag would fetch its siblings under the wrong root, so a
    /// reply must never be offered as one.
    @Test("a reply is not itself a sweep root")
    func repliesAreNotRoots() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        let root = try fixtures.root(at: 2_000)
        let reply = try fixtures.reply(to: root, at: 2_100)
        try await store.ingest(batch: fixtures.channelState + [root, reply], phase: .backfill)

        let candidates = try Self.candidates(store, fixtures, staleBefore: Self.staleBefore)
        #expect(candidates.map(\.rootID) == [root.id])
        #expect(!candidates.contains { $0.rootID == reply.id })
    }

    /// The cap is applied after the ordering, not before it — otherwise a pass would take an
    /// arbitrary subset and the rotation would not converge.
    @Test("the limit takes the front of the rotation")
    func theLimitTakesTheFrontOfTheRotation() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixtures = try Self.Fixtures()

        let roots = try (0 ..< 5).map { try fixtures.root(at: 2_000 + Int64($0)) }
        try await store.ingest(batch: fixtures.channelState + roots, phase: .backfill)
        // Sweep the two newest, so recency and sweep-order disagree.
        try await store.recordThreadSweep(roots: [roots[4].id, roots[3].id], at: 4_000)

        let first = try Self.candidates(store, fixtures, staleBefore: 5_000, limit: 2)
        #expect(first.map(\.rootID) == [roots[2].id, roots[1].id])
    }

    // MARK: - Harness

    private static func candidates(
        _ store: BuzzEventStore,
        _ fixtures: Fixtures,
        staleBefore: Int64,
        limit: Int = 40
    ) throws -> [ThreadSweepCandidate] {
        try store.threadSweepCandidates(
            identity: fixtures.identity, horizon: horizon, staleBefore: staleBefore, limit: limit
        )
    }

    /// One channel this identity is on the roster of, and the events that make it so.
    struct Fixtures {
        let relay: Fixture
        let author: Fixture
        let reader: Fixture

        init() throws {
            relay = try Fixture()
            author = try Fixture()
            reader = try Fixture()
        }

        var identity: String { reader.pubkey }

        var channelState: [NostrEvent] {
            get throws {
                [
                    try relay.event(
                        .groupMetadata, "", tags: [["d", ThreadSweepTests.channel], ["name", "Room"]]
                    ),
                    try relay.event(
                        .groupMembers, "", tags: [["d", ThreadSweepTests.channel], ["p", reader.pubkey]]
                    ),
                ]
            }
        }

        func root(at seconds: Int64, in channel: String = ThreadSweepTests.channel) throws -> NostrEvent {
            try author.message("opener \(seconds)", in: channel, at: seconds)
        }

        func reply(to root: NostrEvent, at seconds: Int64) throws -> NostrEvent {
            try author.event(
                .channelMessage, "a reply",
                tags: [["h", ThreadSweepTests.channel], ["e", root.id, "", "reply"]], at: seconds
            )
        }

        func summary(for root: String, lastReplyAt: Int64) throws -> NostrEvent {
            let content = """
            {"reply_count":1,"descendant_count":1,\
            "last_reply_at":\(lastReplyAt),"participants":[]}
            """
            return try relay.event(
                .threadSummary, content,
                tags: [["e", root], ["d", root], ["h", ThreadSweepTests.channel]], at: 1_700_000_500
            )
        }
    }
}
