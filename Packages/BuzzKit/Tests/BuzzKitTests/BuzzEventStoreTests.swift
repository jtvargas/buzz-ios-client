@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("BuzzEventStore ingest", .timeLimit(.minutes(1)))
struct BuzzEventStoreIngestTests {
    // MARK: - Happy path

    @Test("stores a valid event and reads it back unchanged")
    func storesValid() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let result = try await store.ingest(batch: [event], phase: .live)

        #expect(result.inserted == [event.id])
        #expect(result.duplicates.isEmpty)
        #expect(result.rejected.isEmpty)
        #expect(try await store.count() == 1)

        // A round trip must reproduce the event exactly, or its id would no longer
        // match its contents.
        let stored = try await store.event(id: event.id)
        #expect(stored == event)
        #expect(stored?.isValid == true)
    }

    @Test("an empty batch does nothing")
    func emptyBatch() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let result = try await store.ingest(batch: [], phase: .backfill)
        #expect(result.isEmpty)
    }

    // MARK: - Deduplication

    @Test("re-ingesting the same event is a silent no-op, counted as a duplicate")
    func duplicateReingestIsNoOp() async throws {
        // Reconnect overlap and echoes of our own sends both land here, so this has
        // to be free and silent rather than an error.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let first = try await store.ingest(batch: [event], phase: .backfill)
        let second = try await store.ingest(batch: [event], phase: .live)

        #expect(first.inserted == [event.id])
        #expect(second.inserted.isEmpty)
        #expect(second.duplicates == [event.id])
        #expect(try await store.count() == 1)
    }

    @Test("deduplicates repeats inside a single batch")
    func deduplicatesWithinBatch() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let result = try await store.ingest(batch: [event, event, event], phase: .backfill)

        #expect(result.inserted == [event.id])
        #expect(result.duplicates.count == 2)
        #expect(try await store.count() == 1)
    }

    // MARK: - Adversarial

    @Test("rejects an event whose content was swapped after signing")
    func rejectsTamperedContent() async throws {
        // The attack: a relay serves an event with altered content but the original
        // id and signature. The signature still verifies over that id, so only
        // recomputing the id from the contents catches it. The single most
        // important assertion in the store.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let original = try fixture.message("send 1 sat to alice")

        let tampered = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            createdAt: original.createdAt,
            kind: original.kind,
            tags: original.tags,
            content: "send 1000 sats to mallory",
            sig: original.sig
        )

        let result = try await store.ingest(batch: [tampered], phase: .live)

        #expect(result.inserted.isEmpty)
        #expect(result.rejected == [Rejection(id: original.id, reason: .idMismatch)])
        #expect(try await store.count() == 0)
    }

    @Test("rejects an event whose id was tampered with")
    func rejectsTamperedID() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let flipped = String(event.id.dropLast()) + (event.id.hasSuffix("0") ? "1" : "0")
        let tampered = NostrEvent(
            id: flipped,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: event.sig
        )

        let result = try await store.ingest(batch: [tampered], phase: .live)

        #expect(result.rejected == [Rejection(id: flipped, reason: .idMismatch)])
        #expect(try await store.count() == 0)
    }

    @Test("rejects a well-formed event with a corrupted signature")
    func rejectsBadSignature() async throws {
        // The id is a correct hash of the contents, so only the signature check can
        // catch this — the other half of validation.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let flipped = String(event.sig.dropLast()) + (event.sig.hasSuffix("0") ? "1" : "0")
        let forged = NostrEvent(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: flipped
        )

        let result = try await store.ingest(batch: [forged], phase: .live)

        #expect(result.rejected == [Rejection(id: event.id, reason: .badSignature)])
        #expect(try await store.count() == 0)
    }

    @Test("rejects an event reattributed to someone who never signed it")
    func rejectsForgedAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let victim = try Fixture()
        let attacker = try Fixture()
        let real = try attacker.message("I am the victim")

        // Same fields and signature, but the id is recomputed over the victim's
        // pubkey, so the id matches the victim's fields while the signature was made
        // by the attacker — caught by the signature check.
        let forged = NostrEvent(
            id: NostrEvent.computeID(
                pubkey: victim.pubkey,
                createdAt: real.createdAt,
                kind: real.kind,
                tags: real.tags,
                content: real.content
            ).hexString,
            pubkey: victim.pubkey,
            createdAt: real.createdAt,
            kind: real.kind,
            tags: real.tags,
            content: real.content,
            sig: real.sig
        )

        let result = try await store.ingest(batch: [forged], phase: .live)

        #expect(result.inserted.isEmpty)
        #expect(result.rejected.map(\.reason) == [.badSignature])
        #expect(try await store.count() == 0)
    }

    @Test("keeps the valid events from a batch containing an invalid one")
    func partialBatch() async throws {
        // A relay serving one bad event must not cost us the whole batch.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let good1 = try fixture.message("first", at: 1000)
        let good2 = try fixture.message("second", at: 2000)
        let bad = NostrEvent(
            id: good1.id, pubkey: good1.pubkey, createdAt: good1.createdAt,
            kind: good1.kind, tags: good1.tags, content: "altered", sig: good1.sig
        )

        let result = try await store.ingest(batch: [good1, bad, good2], phase: .backfill)

        #expect(Set(result.inserted) == Set([good1.id, good2.id]))
        #expect(result.rejected.count == 1)
        #expect(try await store.count() == 2)
    }

    // MARK: - Ephemeral diversion

    @Test("diverts ephemeral kinds 20001/20002 and never writes them")
    func divertsEphemeral() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let presence = try fixture.event(.presence, "online", tags: [["h", "room-1"]])
        let typing = try fixture.event(.typing, "", tags: [["h", "room-1"]])
        let message = try fixture.message("real")

        let result = try await store.ingest(batch: [presence, typing, message], phase: .live)

        #expect(result.ephemeral.map(\.id) == [presence.id, typing.id])
        #expect(result.inserted == [message.id])
        // Diverted, not stored.
        #expect(try await store.count() == 1)
        #expect(try await store.count(kind: .presence) == 0)
        #expect(try await store.count(kind: .typing) == 0)
    }

    @Test("still verifies ephemeral events before diverting them")
    func verifiesEphemeral() async throws {
        // A forged presence event is rejected, not handed on: the caller is going to
        // act on whatever comes back in `ephemeral`.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let real = try fixture.event(.presence, "online")
        let forged = NostrEvent(
            id: real.id, pubkey: real.pubkey, createdAt: real.createdAt,
            kind: real.kind, tags: real.tags, content: "away", sig: real.sig
        )

        let result = try await store.ingest(batch: [forged], phase: .live)

        #expect(result.ephemeral.isEmpty)
        #expect(result.rejected.count == 1)
    }

    // MARK: - Tag indexing

    @Test("indexes single-letter tags only")
    func indexesSingleLetterTags() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let event = try fixture.event(
            .channelMessage,
            "x",
            tags: [["h", "room-1"], ["p", "abc"], ["client", "hive"], ["relay", "wss://x"]]
        )

        _ = try await store.ingest(batch: [event], phase: .live)

        let names = try await store.strings("SELECT name FROM event_tag ORDER BY name", column: "name")
        #expect(names == ["h", "p"])
    }
}
