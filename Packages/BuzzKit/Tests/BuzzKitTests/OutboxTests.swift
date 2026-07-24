@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

@Suite("Outbox state machine", .timeLimit(.minutes(1)))
struct OutboxTests {
    // MARK: - Harness

    /// A clock a test can wind forward, so age-based decisions (the stale-timestamp
    /// re-sign) are exercised without touching the wall clock.
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) { current = start }

        var now: Date { lock.withLock { current } }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }

        var reader: @Sendable () -> Date {
            { [self] in self.now }
        }
    }

    /// One identity and one store on a fresh temp database, wired to `clock`.
    struct Harness {
        let store: BuzzEventStore
        let database: TempDatabase
        let signer: InMemorySigner
        let pubkey: String
        let clock: MutableClock

        init(start: TimeInterval = 1_700_000_000) throws {
            let key = try PrivateKey()
            signer = InMemorySigner(key)
            pubkey = key.publicKey.hex
            clock = MutableClock(Date(timeIntervalSince1970: start))
            database = TempDatabase()
            store = try BuzzEventStore(path: database.path, projector: NullProjector(), clock: clock.reader)
        }

        func remove() { database.remove() }

        /// The `state` column of a row, read raw so a test asserts persisted state
        /// rather than a value the store handed back.
        func rawState(_ eventID: String) async throws -> String? {
            try await store.reader.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT state FROM outbox WHERE event_id = ?",
                    arguments: [eventID]
                )
            }
        }
    }

    // MARK: - Enqueue

    @Test("enqueue signs and inserts a pending row with denormalized columns")
    func enqueueInsertsPending() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(
            content: "hello",
            in: "room-1",
            tags: [["h", "room-1"]],
            with: harness.signer
        )

        #expect(entry.state == .pending)
        #expect(entry.attempts == 0)
        #expect(entry.channelID == "room-1")
        #expect(entry.event.content == "hello")
        // Signed at the injected clock, not the wall clock.
        #expect(entry.event.createdAt == 1_700_000_000)
        #expect(entry.id == entry.event.id)
        #expect(try await store.outboxCount() == 1)

        // The row round-trips through the store's own read path.
        #expect(try await store.entry(id: entry.id) == entry)

        // The denormalized columns are populated from the event, not just the
        // payload — that is what lets the timeline union pending rows cheaply.
        let columns = try await store.reader.read { db -> [String: String]? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT pubkey, content, channel_id FROM outbox WHERE event_id = ?",
                arguments: [entry.id]
            ) else { return nil }
            return ["pubkey": row["pubkey"], "content": row["content"], "channel_id": row["channel_id"]]
        }
        #expect(columns?["pubkey"] == harness.pubkey)
        #expect(columns?["content"] == "hello")
        #expect(columns?["channel_id"] == "room-1")

        // The event is queued, not yet in the log.
        #expect(try await store.count() == 0)
    }

    @Test("a shared id means a re-enqueue of the same message is a no-op")
    func enqueueIsIdempotentById() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        // The event id is a hash of the message's fields, so signing the same
        // content at the same instant yields the same id. The second enqueue hits
        // ON CONFLICT and must not duplicate the row.
        let first = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        let second = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)

        #expect(second.id == first.id)
        #expect(try await store.outboxCount() == 1)
    }

    // MARK: - Content ceiling

    @Test("enqueue rejects content over the ceiling and accepts content at it")
    func enqueueEnforcesCeiling() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        // Exactly at the ceiling is allowed.
        let atLimit = String(repeating: "a", count: OutboxPolicy.maxContentBytes)
        let ok = try await store.enqueue(content: atLimit, in: "room-1", with: harness.signer)
        #expect(ok.event.content.utf8.count == OutboxPolicy.maxContentBytes)

        // One byte over is a caller error, surfaced — never truncated.
        let tooBig = String(repeating: "a", count: OutboxPolicy.maxContentBytes + 1)
        await #expect(throws: OutboxError.contentTooLarge(
            bytes: OutboxPolicy.maxContentBytes + 1,
            limit: OutboxPolicy.maxContentBytes
        )) {
            try await store.enqueue(content: tooBig, in: "room-1", with: harness.signer)
        }
        // The rejected message left no row behind.
        #expect(try await store.outboxCount() == 1)
    }

    @Test("the ceiling is parameterized and measured in UTF-8 bytes, not characters")
    func ceilingIsBytesAndParameterized() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        // Ten ASCII bytes under a limit of ten is allowed.
        _ = try await store.enqueue(
            content: "0123456789",
            in: "room-1",
            with: harness.signer,
            maxContentBytes: 10
        )

        // Three emoji are three characters but twelve UTF-8 bytes: the ceiling is a
        // byte ceiling, matching the relay's, so this is rejected.
        await #expect(throws: OutboxError.contentTooLarge(bytes: 12, limit: 10)) {
            try await store.enqueue(
                content: "😀😀😀",
                in: "room-1",
                with: harness.signer,
                maxContentBytes: 10
            )
        }
    }

    // MARK: - Transitions

    @Test("markSending moves to sending and counts the attempt")
    func markSendingCountsAttempt() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.markSending(entry.id)

        let after = try await store.entry(id: entry.id)
        #expect(after?.state == .sending)
        #expect(after?.attempts == 1)
    }

    @Test("confirmSent moves queue to log in one transaction")
    func confirmSentMovesToLog() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", tags: [["h", "room-1"]], with: harness.signer)
        try await store.markSending(entry.id)
        try await store.confirmSent(entry.event)

        // Present in the log under the same id, absent from the queue — never both,
        // never neither.
        #expect(try await store.count() == 1)
        #expect(try await store.event(id: entry.id) == entry.event)
        #expect(try await store.outboxCount() == 0)
    }

    @Test("confirmSent refuses an event that fails verification")
    func confirmSentVerifies() async throws {
        // The confirm path is the same choke point as ingest: a tampered event is
        // rejected rather than opening a second, unverified route into the log.
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "send 1 sat", in: "room-1", with: harness.signer)
        let tampered = NostrEvent(
            id: entry.event.id,
            pubkey: entry.event.pubkey,
            createdAt: entry.event.createdAt,
            kind: entry.event.kind,
            tags: entry.event.tags,
            content: "send 1000 sats",
            sig: entry.event.sig
        )

        await #expect(throws: OutboxError.invalidEvent(entry.event.id)) {
            try await store.confirmSent(tampered)
        }
        // Nothing entered the log, and the queue row still stands.
        #expect(try await store.count() == 0)
        #expect(try await store.outboxCount() == 1)
    }

    @Test("markFailed records the reason and stops auto-resend")
    func markFailedRecordsReason() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.markFailed(entry.id, error: "restricted: not a member")

        let after = try await store.entry(id: entry.id)
        #expect(after?.state == .failed)
        #expect(after?.lastError == "restricted: not a member")
        // Failed sends are surfaced, not drained.
        #expect(try await store.pendingSends().isEmpty)
        #expect(try await store.failedSends().map(\.id) == [entry.id])
    }

    @Test("discard removes a queued send")
    func discardRemoves() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.discard(entry.id)

        #expect(try await store.entry(id: entry.id) == nil)
        #expect(try await store.outboxCount() == 0)
    }

    @Test("retry returns a failed send to pending with a fresh budget")
    func retryResetsFailed() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.markSending(entry.id)
        try await store.markFailed(entry.id, error: "error: try later")

        try await store.retry(entry.id)

        let after = try await store.entry(id: entry.id)
        #expect(after?.state == .pending)
        #expect(after?.attempts == 0)
        #expect(after?.lastError == nil)
        #expect(try await store.pendingSends().map(\.id) == [entry.id])
    }

    // MARK: - Drain semantics

    @Test("pendingSends includes sending rows and excludes failed, oldest first")
    func pendingSendsResendSemantics() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let m1 = try await store.enqueue(content: "first", in: "room-1", with: harness.signer)
        harness.clock.advance(by: 10)
        let m2 = try await store.enqueue(content: "second", in: "room-1", with: harness.signer)

        // m1 was handed to the relay; the outcome is unknown, so a drain must still
        // resend it — the relay dedupes by id.
        try await store.markSending(m1.id)

        let queued = try await store.pendingSends()
        #expect(queued.map(\.id) == [m1.id, m2.id])
        #expect(queued.first?.state == .sending)
        #expect(queued.last?.state == .pending)

        // A failed row drops out of the drain set.
        try await store.markFailed(m2.id, error: "blocked: policy")
        #expect(try await store.pendingSends().map(\.id) == [m1.id])
        #expect(try await store.failedSends().map(\.id) == [m2.id])
    }

    // MARK: - Disposition mapping

    @Test("duplicate is treated as success and confirmed into the log")
    func resolveDuplicateConfirms() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", tags: [["h", "room-1"]], with: harness.signer)
        try await store.markSending(entry.id)

        let outcome = try await store.resolve(
            OKReason(message: "duplicate: have it"),
            for: entry.id,
            with: harness.signer
        )
        #expect(outcome == .confirmed)
        #expect(try await store.count() == 1)
        #expect(try await store.outboxCount() == 0)
    }

    @Test("terminal rejections fail the send")
    func resolveTerminalFails() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        for message in ["restricted: no", "blocked: policy", "pow: 20"] {
            let entry = try await store.enqueue(content: message, in: "room-1", with: harness.signer)
            try await store.markSending(entry.id)
            let outcome = try await store.resolve(OKReason(message: message), for: entry.id, with: harness.signer)
            #expect(outcome == .failed(OKReason(message: message).humanForTest))
            #expect(try await harness.rawState(entry.id) == OutboxState.failed.rawValue)
        }
    }

    @Test("auth-required parks the send awaiting re-auth, still drainable")
    func resolveAuthRequiredParks() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.markSending(entry.id)

        let outcome = try await store.resolve(
            OKReason(message: "auth-required: please NIP-42"),
            for: entry.id,
            with: harness.signer
        )
        #expect(outcome == .awaitingReauth)
        #expect(try await harness.rawState(entry.id) == OutboxState.awaitingReauth.rawValue)
        // It waits on auth, not on the user: still part of the drain set.
        #expect(try await store.pendingSends().map(\.id) == [entry.id])
    }

    @Test("transient rejections return the send to pending for another drain")
    func resolveRetryableRequeues() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        for message in ["rate-limited: slow down", "error: transient", "weird no prefix"] {
            let entry = try await store.enqueue(content: message, in: "room-1", with: harness.signer)
            try await store.markSending(entry.id)
            let outcome = try await store.resolve(OKReason(message: message), for: entry.id, with: harness.signer)
            #expect(outcome == .retrying(attempts: 1))
            #expect(try await harness.rawState(entry.id) == OutboxState.pending.rawValue)
        }
    }

    @Test("a fresh invalid rejection is terminal, not re-signed")
    func resolveInvalidFreshFails() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.markSending(entry.id)

        // No time has passed, so this invalid: is a real rejection, not the
        // timestamp gate closing.
        let outcome = try await store.resolve(
            OKReason(message: "invalid: bad shape"),
            for: entry.id,
            with: harness.signer
        )
        #expect(outcome == .failed("bad shape"))
        #expect(try await harness.rawState(entry.id) == OutboxState.failed.rawValue)
        #expect(try await store.outboxCount() == 1)
    }

    // MARK: - Attempt cap

    @Test("transient rejections fail the send once the attempt cap is reached")
    func attemptCapFailsEventually() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)

        func fail(_ text: String) async throws -> OutboxResolution {
            try await store.resolve(OKReason(message: text), for: entry.id, with: harness.signer, maxAttempts: 3)
        }

        // Under the cap: each send bumps attempts and the send returns to pending.
        try await store.markSending(entry.id) // attempts = 1
        #expect(try await fail("error: 1") == .retrying(attempts: 1))
        try await store.markSending(entry.id) // attempts = 2
        #expect(try await fail("error: 2") == .retrying(attempts: 2))

        // Hitting the cap turns the next transient rejection terminal.
        try await store.markSending(entry.id) // attempts = 3
        #expect(try await fail("error: 3") == .exhausted("3"))
        #expect(try await harness.rawState(entry.id) == OutboxState.failed.rawValue)
    }

    // MARK: - Stale-timestamp re-sign (T4, store level)

    @Test("isStale turns on age past the threshold")
    func isStaleBoundary() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        let fresh = await store.isStale(entry)
        #expect(fresh == false)

        // Exactly at the threshold is not yet stale (the gate is strictly greater).
        harness.clock.advance(by: OutboxPolicy.staleAfter)
        let atThreshold = await store.isStale(entry)
        #expect(atThreshold == false)

        harness.clock.advance(by: 1)
        let pastThreshold = await store.isStale(entry)
        #expect(pastThreshold == true)
    }

    @Test("a stale pending send re-signs with a new id and swaps identity")
    func reSignSwapsIdentity() async throws {
        // T4 at store level: a message composed offline, drained twenty minutes
        // later. Its original timestamp would trip the relay's ±15-minute gate, so
        // it must be re-signed before it can land.
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let old = try await store.enqueue(content: "m2", in: "room-1", tags: [["h", "room-1"]], with: harness.signer)
        harness.clock.advance(by: 1200) // 20 minutes

        let fresh = try await store.reSign(old.id, with: harness.signer)

        // A new identity, a fresh timestamp, the same message.
        #expect(fresh.id != old.id)
        #expect(fresh.event.content == "m2")
        #expect(fresh.event.createdAt == 1_700_000_000 + 1200)
        #expect(fresh.state == .pending)

        // The old id is gone from the outbox and was never in the log — safe,
        // because the relay never saw it.
        #expect(try await store.entry(id: old.id) == nil)
        #expect(try await store.event(id: old.id) == nil)
        #expect(try await store.event(id: fresh.id) == nil)

        // Exactly one queued row, carrying the original content.
        #expect(try await store.outboxCount() == 1)
        let onlyRow = try await store.reader.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM outbox")
        }
        #expect(onlyRow == "m2")
    }

    @Test("an invalid rejection on an aged sending row re-signs and requeues")
    func resolveInvalidStaleReSigns() async throws {
        // The sending-row path: sent as-is first, and only the invalid: plus local
        // age — never the reason text — triggers the re-sign.
        let harness = try Harness()
        defer { harness.remove() }
        let store = harness.store

        let old = try await store.enqueue(content: "m2", in: "room-1", tags: [["h", "room-1"]], with: harness.signer)
        try await store.markSending(old.id)
        harness.clock.advance(by: 1200)

        let outcome = try await store.resolve(
            OKReason(message: "invalid: event timestamp too far from server time"),
            for: old.id,
            with: harness.signer
        )

        guard case let .resigned(newID) = outcome else {
            Issue.record("expected a re-sign, got \(outcome)")
            return
        }
        #expect(newID != old.id)
        #expect(try await store.entry(id: old.id) == nil)

        // Drive the re-signed send to a successful landing and assert the invariant
        // T4 pins: exactly one message with the original content, the old id in
        // neither the outbox nor the log.
        let resignedEntry = try await store.entry(id: newID)
        let fresh = try #require(resignedEntry)
        try await store.markSending(newID)
        try await store.confirmSent(fresh.event)

        #expect(try await store.count() == 1)
        #expect(try await store.event(id: newID)?.content == "m2")
        #expect(try await store.event(id: old.id) == nil)
        #expect(try await store.outboxCount() == 0)
    }
}

// MARK: - Test helpers

private extension OKReason {
    /// The human remainder, mirrored in the test so an assertion can name the exact
    /// string the store records without reaching into the store's private helper.
    var humanForTest: String {
        switch self {
        case let .duplicate(text), let .pow(text), let .rateLimited(text), let .invalid(text),
             let .restricted(text), let .authRequired(text), let .blocked(text), let .error(text),
             let .unspecified(text):
            text
        }
    }
}
