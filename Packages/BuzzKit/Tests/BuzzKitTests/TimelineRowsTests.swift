@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The by-id read, against the definition of a row the paging reads use.
///
/// `rows(for:)` exists so a surface holding rows from several pages can re-read the ones
/// its newest page no longer speaks for. That only works if it agrees with the page about
/// what a row *is*: an id the channel page returned and this read silently drops is a row
/// that can never be refreshed again, and the disagreement is invisible until some later
/// kind depends on it.
@Suite("Timeline rows by id", .timeLimit(.minutes(1)))
struct TimelineRowsTests {
    /// The body shape a relay publishes for a kind-40099 membership notice.
    private func noticeBody(actor: String, target: String) -> String {
        #"{"type":"member_joined","actor":"\#(actor)","target":"\#(target)"}"#
    }

    @Test("returns every kind the channel page returns, notices included")
    func returnsNoticesAsWellAsMessages() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let peer = try Fixture()

        let message = try fixture.message("m0", in: "room-1", at: 1_000)
        let notice = try fixture.event(
            .systemMessage,
            noticeBody(actor: fixture.pubkey, target: peer.pubkey),
            tags: [["h", "room-1"]],
            at: 1_001
        )
        _ = try await store.ingest(batch: [message, notice], phase: .backfill)

        // The premise: both are rows of the channel page, so both are ids a caller holds.
        let page = try store.timeline(channel: "room-1")
        #expect(page.count == 2)

        let refreshed = try store.rows(for: page.map(\.id))
        #expect(Set(refreshed.map(\.id)) == Set(page.map(\.id)))

        let row = try #require(refreshed.first { $0.id == notice.id })
        #expect(row.isNotice)
        #expect(row.notice == .memberJoined(actor: fixture.pubkey, target: peer.pubkey))
    }

    @Test("a notice still reads as deleted once a relay tombstone names it")
    func noticeCarriesDeletionThroughTheByIDRead() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let peer = try Fixture()

        let notice = try fixture.event(
            .systemMessage,
            noticeBody(actor: fixture.pubkey, target: peer.pubkey),
            tags: [["h", "room-1"]],
            at: 1_000
        )
        _ = try await store.ingest(batch: [notice], phase: .backfill)
        #expect(try store.rows(for: [notice.id]).first?.isDeleted == false)

        // Why the refresh must carry notices rather than skip them as inert: a notice
        // takes no edit and no reply, but a relay tombstone applies to one through the
        // same read-time authority predicate as any message. Skipping it at the caller
        // would leave a retracted notice on screen for the life of the surface — the same
        // staleness this read exists to prevent.
        let tombstone = try peer.event(
            .groupDeleteEvent, "", tags: [["h", "room-1"], ["e", notice.id]], at: 1_001
        )
        _ = try await store.ingest(batch: [tombstone], phase: .live)

        #expect(try store.rows(for: [notice.id]).first?.isDeleted == true)
    }

    @Test("an id the log does not hold is absent rather than an error")
    func unknownIDIsAbsent() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let message = try fixture.message("m0", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [message], phase: .backfill)

        let rows = try store.rows(for: [message.id, String(repeating: "f", count: 64)])
        #expect(rows.map(\.id) == [message.id])
        #expect(try store.rows(for: []).isEmpty)
    }
}
