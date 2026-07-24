@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

@Suite("Outbox disposition and re-sign", .timeLimit(.minutes(1)))
struct OutboxDispositionTests {
    // MARK: - Disposition mapping

    @Test("duplicate is treated as success and confirmed into the log")
    func resolveDuplicateConfirms() async throws {
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
        let harness = try OutboxHarness()
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
