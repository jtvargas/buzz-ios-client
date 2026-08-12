@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

@Suite("Outbox state machine", .timeLimit(.minutes(1)))
struct OutboxTests {
    // MARK: - Enqueue

    @Test("enqueue signs and inserts a pending row with denormalized columns")
    func enqueueInsertsPending() async throws {
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "hi", in: "room-1", with: harness.signer)
        try await store.discard(entry.id)

        #expect(try await store.entry(id: entry.id) == nil)
        #expect(try await store.outboxCount() == 0)
    }

    @Test("retry returns a failed send to pending with a fresh budget")
    func retryResetsFailed() async throws {
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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

    // MARK: - Superseding a queued addressable event

    /// An addressable event (NIP-33: kind + author + `d`) has one live version, so two of them
    /// queued for the same address means the older is a turn taken in front of whatever the
    /// reader typed, for a value the relay overwrites a moment later. This queue drains one at
    /// a time, each awaiting its own `OK`, which is what makes that a cost and not a curiosity.
    @Test("a newer addressable send drops the queued older one for the same d tag")
    func supersedeDropsOlderQueued() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let store = harness.store

        let older = try await store.enqueue(
            kind: .readState,
            content: "older",
            in: "",
            tags: [["d", "read-state:slot-a"], ["t", "read-state"]],
            with: harness.signer
        )
        harness.clock.advance(by: 10)
        let newer = try await store.enqueue(
            kind: .readState,
            content: "newer",
            in: "",
            tags: [["d", "read-state:slot-a"], ["t", "read-state"]],
            with: harness.signer
        )
        #expect(try await store.outboxCount() == 2)

        let dropped = try await store.supersedeQueuedAddressable(
            kind: .readState,
            dTag: "read-state:slot-a",
            keeping: newer.id
        )

        #expect(dropped == 1)
        #expect(try await store.pendingSends().map(\.id) == [newer.id])
        #expect(try await store.entry(id: older.id) == nil)
    }

    /// Three things it must not touch, each for a different reason.
    @Test("supersede leaves another address, another kind, and a row already in flight")
    func supersedeIsNarrow() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let store = harness.store

        // A different slot is a different address; nothing about it is replaced.
        let otherSlot = try await store.enqueue(
            kind: .readState,
            content: "other slot",
            in: "",
            tags: [["d", "read-state:slot-b"], ["t", "read-state"]],
            with: harness.signer
        )
        // An ordinary message shares an address with nothing and is never replaceable.
        let message = try await store.enqueue(content: "hello", in: "room-1", with: harness.signer)
        // Same address, but already handed to the relay: its `OK` is still expected and the
        // relay dedupes by id, so the drain owns that row's fate rather than this.
        let inFlight = try await store.enqueue(
            kind: .readState,
            content: "in flight",
            in: "",
            tags: [["d", "read-state:slot-a"], ["t", "read-state"]],
            with: harness.signer
        )
        try await store.markSending(inFlight.id)

        harness.clock.advance(by: 10)
        let newer = try await store.enqueue(
            kind: .readState,
            content: "newer",
            in: "",
            tags: [["d", "read-state:slot-a"], ["t", "read-state"]],
            with: harness.signer
        )

        let dropped = try await store.supersedeQueuedAddressable(
            kind: .readState,
            dTag: "read-state:slot-a",
            keeping: newer.id
        )

        #expect(dropped == 0)
        #expect(try await store.outboxCount() == 4)
        for id in [otherSlot.id, message.id, inFlight.id, newer.id] {
            #expect(try await store.entry(id: id) != nil)
        }
    }
}
