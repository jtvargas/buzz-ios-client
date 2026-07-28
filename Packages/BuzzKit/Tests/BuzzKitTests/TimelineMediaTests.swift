@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// What a message's attachments look like by the time a row reaches a reader.
///
/// The projection is the only place `imeta` is read, so these are the tests that decide
/// whether a picture exists at all: a renderer cannot draw what the row does not carry.
/// The edit cases carry the weight — an edit publishes a whole new tag set, and taking
/// its words while keeping the original's pictures would show a message nobody sent.
@Suite("Timeline media", .timeLimit(.minutes(1)))
struct TimelineMediaTests {
    private static let picture = "https://relay.example/media/abc.png"
    private static let other = "https://relay.example/media/def.jpg"

    private static func imeta(_ url: String, _ fields: String...) -> [String] {
        ["imeta", "url \(url)"] + fields
    }

    // MARK: - Carried onto the row

    @Test("a message's imeta tags reach its row")
    func mediaOnRow() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [
            fixture.event(
                .channelMessage,
                "look ![image](\(Self.picture))",
                tags: [["h", "room-1"], Self.imeta(Self.picture, "m image/png", "dim 1200x800", "alt a graph")],
                at: 1000
            ),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        let media = try #require(row.media.first)
        #expect(row.media.count == 1)
        #expect(media.url == Self.picture)
        #expect(media.kind == .image)
        #expect(media.alt == "a graph")
        // The reservation the scroll engine needs, decided before a byte is fetched.
        #expect(media.aspectRatio == 1.5)
    }

    @Test("a message with no imeta carries no media")
    func noMedia() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [fixture.message("just words", at: 1000)], phase: .backfill)

        #expect(try store.timeline(channel: "room-1").first?.media.isEmpty == true)
    }

    @Test("a thread read carries media too")
    func threadCarriesMedia() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let opener = try fixture.message("opener", at: 1000)

        _ = try await store.ingest(batch: [
            opener,
            fixture.event(
                .channelMessage,
                "![image](\(Self.picture))",
                tags: [["h", "room-1"], ["e", opener.id, "", "reply"], Self.imeta(Self.picture, "m image/png")],
                at: 1001
            ),
        ], phase: .backfill)

        let reply = try #require(try store.thread(root: opener.id).last)
        #expect(reply.media.map(\.url) == [Self.picture])
    }

    // MARK: - Edits publish a whole new tag set

    @Test("an authorized edit's imeta replaces the original's")
    func editReplacesMedia() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.event(
            .channelMessage,
            "![image](\(Self.picture))",
            tags: [["h", "room-1"], Self.imeta(Self.picture, "m image/png")],
            at: 1000
        )

        _ = try await store.ingest(batch: [
            message,
            fixture.event(
                .messageEdit,
                "![image](\(Self.other))",
                tags: [["e", message.id], Self.imeta(Self.other, "m image/jpeg", "alt the replacement")],
                at: 1001
            ),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.isEdited)
        #expect(row.media.map(\.url) == [Self.other])
        #expect(row.media.first?.alt == "the replacement")
    }

    @Test("an edit that carries no imeta withdraws the attachment")
    func editWithdrawsMedia() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.event(
            .channelMessage,
            "![image](\(Self.picture))",
            tags: [["h", "room-1"], Self.imeta(Self.picture, "m image/png")],
            at: 1000
        )

        _ = try await store.ingest(batch: [
            message,
            fixture.event(.messageEdit, "never mind", tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        #expect(try store.timeline(channel: "room-1").first?.media.isEmpty == true)
    }

    @Test("an unauthorized edit changes neither the words nor the pictures")
    func strangerEditIgnored() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let stranger = try Fixture()
        let message = try author.event(
            .channelMessage,
            "mine",
            tags: [["h", "room-1"], Self.imeta(Self.picture, "m image/png")],
            at: 1000
        )

        _ = try await store.ingest(batch: [
            message,
            stranger.event(
                .messageEdit,
                "not mine",
                tags: [["e", message.id], Self.imeta(Self.other, "m image/jpeg")],
                at: 1001
            ),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "mine")
        #expect(row.media.map(\.url) == [Self.picture])
    }

    @Test("the newest authorized edit wins, and its own tags come with it")
    func newestEditWins() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("original", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            fixture.event(
                .messageEdit,
                "first",
                tags: [["e", message.id], Self.imeta(Self.picture, "m image/png")],
                at: 1001
            ),
            fixture.event(
                .messageEdit,
                "second",
                tags: [["e", message.id], Self.imeta(Self.other, "m image/jpeg")],
                at: 1002
            ),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "second")
        #expect(row.media.map(\.url) == [Self.other])
    }

    // MARK: - Still in flight

    @Test("a queued message shows its own attachments before the relay has it")
    func pendingRowCarriesMedia() async throws {
        let harness = try OutboxHarness()
        defer { harness.database.remove() }

        try await harness.store.enqueue(
            content: "![image](\(Self.picture))",
            in: "room-1",
            tags: [["h", "room-1"], Self.imeta(Self.picture, "m image/png", "dim 400x400")],
            with: harness.signer
        )

        let row = try #require(try harness.store.timeline(channel: "room-1").first)
        #expect(row.delivery == .pending)
        #expect(row.media.map(\.url) == [Self.picture])
        #expect(row.media.first?.aspectRatio == 1)
    }
}
