@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("Channel lifetime")
struct ChannelLifetimeTests {
    @Test("projects ephemeral lifetime tags as nullable integers")
    func projectsLifetime() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(
                .groupMetadata,
                #"{"name":"Huddle"}"#,
                tags: [
                    ["d", "room-1"],
                    ["ttl", "3600"],
                    ["ttl_deadline", "2026-08-10T19:53:00.123456+00:00"],
                ],
                at: 1000
            ),
        ], phase: .backfill)

        #expect(try await store.strings(
            """
            SELECT CAST(ttl_seconds AS TEXT) || '|' || CAST(ttl_deadline AS TEXT) AS lifetime
              FROM channel WHERE id = 'room-1'
            """,
            column: "lifetime"
        ) == ["3600|1786391580"])

        _ = try await store.ingest(batch: [
            relay.event(
                .groupMetadata,
                #"{"name":"Ordinary"}"#,
                tags: [["d", "room-1"]],
                at: 1001
            ),
        ], phase: .live)

        #expect(try await store.strings(
            "SELECT typeof(ttl_seconds) || '|' || typeof(ttl_deadline) AS lifetime FROM channel",
            column: "lifetime"
        ) == ["null|null"])
    }

    @Test("exposes ephemeral metadata and formats its remaining lifetime")
    func formatsLifetime() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let now = Date(timeIntervalSince1970: 1_000)

        _ = try await store.ingest(batch: [
            relay.event(
                .groupMetadata,
                #"{"name":"Huddle"}"#,
                tags: [
                    ["d", "huddle"],
                    ["ttl", "3600"],
                    ["ttl_deadline", "1970-01-01T00:16:40Z"],
                ],
                at: 500
            ),
            relay.event(.groupMetadata, #"{"name":"Ordinary"}"#, tags: [["d", "ordinary"]], at: 500),
        ], phase: .backfill)

        let huddle = try #require(try store.channelList().first { $0.id == "huddle" })
        #expect(huddle.ttlSeconds == 3_600)
        #expect(huddle.ttlDeadline == 1_000)
        #expect(huddle.isEphemeral)
        #expect(huddle.ephemeralLifetimeLabel(at: now) == "Cleanup due")

        let ordinary = try #require(try store.channelList().first { $0.id == "ordinary" })
        #expect(!ordinary.isEphemeral)
        #expect(ordinary.ephemeralLifetimeLabel(at: now) == nil)

        #expect(channel(deadline: 1_060).ephemeralLifetimeLabel(at: now) == "1m left")
        #expect(channel(deadline: 1_061).ephemeralLifetimeLabel(at: now) == "2m left")
        #expect(channel(deadline: 8_200).ephemeralLifetimeLabel(at: now) == "2h left")
        #expect(channel(deadline: 87_400).ephemeralLifetimeLabel(at: now) == "1d left")
        #expect(channel(ttl: 3_600).ephemeralLifetimeLabel(at: now) == "1h TTL")
    }

    private func channel(ttl: Int64? = nil, deadline: Int64? = nil) -> ChannelListRow {
        ChannelListRow(
            id: "channel",
            name: nil,
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil,
            ttlSeconds: ttl,
            ttlDeadline: deadline
        )
    }
}
