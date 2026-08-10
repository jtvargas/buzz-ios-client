@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// A huddle channel is not marked as one by the relay: it is an ordinary `stream` channel
/// with a TTL, and the only thing that says otherwise is the kind-48100 published in the
/// channel it was started from. These cover the link that carries that, and the two ways
/// it could plausibly be got wrong.
@Suite("Huddle projection")
struct HuddleProjectionTests {
    private static let parent = "parent-channel"
    private static let room = "54c9b77f-b63e-4cb8-b032-f4b4123aa990"
    private static let body = #"{"ephemeral_channel_id":"54c9b77f-b63e-4cb8-b032-f4b4123aa990"}"#

    @Test("a huddle start names the room it runs in, not the channel it was started from")
    func projectsStart() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(.huddleStarted, Self.body, tags: [["h", Self.parent]], at: 1_000),
        ], phase: .backfill)

        // The `h` scope is where the "started a huddle" row is read; the *body* is the
        // room. Reading the scope as the room would mark the parent channel a huddle and
        // leave the huddle itself unmarked — both wrong, and in a way an `isHuddle`
        // assertion alone would not distinguish.
        #expect(try await store.strings(
            "SELECT channel_id || '|' || parent_id AS link FROM huddle",
            column: "link"
        ) == ["\(Self.room)|\(Self.parent)"])
    }

    @Test("an end that arrives before its start still marks the room")
    func projectsOutOfOrder() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        // The order a rebuild can replay them in, and the order a relay can resend them
        // in after a reconnect. The projection has to land the same either way or the
        // version-bump rebuild would disagree with live ingest.
        _ = try await store.ingest(batch: [
            relay.event(.huddleEnded, Self.body, tags: [["h", Self.parent]], at: 2_000),
        ], phase: .backfill)
        _ = try await store.ingest(batch: [
            relay.event(.huddleStarted, Self.body, tags: [["h", Self.parent]], at: 1_000),
        ], phase: .live)

        #expect(try await store.strings(
            "SELECT CAST(started_at AS TEXT) AS t FROM huddle",
            column: "t"
        ) == ["1000"])
    }

    @Test("the sidebar reads a huddle as a huddle and an ordinary channel as not one")
    func exposesIsHuddle() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(
                .groupMetadata,
                #"{"name":"magnus-health huddle"}"#,
                tags: [["d", Self.room], ["t", "stream"], ["ttl", "3600"]],
                at: 500
            ),
            relay.event(
                .groupMetadata,
                #"{"name":"magnus-health"}"#,
                tags: [["d", Self.parent], ["t", "stream"]],
                at: 500
            ),
            relay.event(.huddleStarted, Self.body, tags: [["h", Self.parent]], at: 1_000),
        ], phase: .backfill)

        let rows = try store.channelList()
        let huddle = try #require(rows.first { $0.id == Self.room })
        let ordinary = try #require(rows.first { $0.id == Self.parent })

        #expect(huddle.isHuddle)
        #expect(huddle.isEphemeral)
        // The channel the huddle was started *from* is neither, which is the half of this
        // that a body/scope mix-up would invert.
        #expect(!ordinary.isHuddle)
        #expect(!ordinary.isEphemeral)
    }

    @Test("a body naming no room records nothing")
    func ignoresUnreadableBody() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(.huddleStarted, "not json", tags: [["h", Self.parent]], at: 1_000),
            relay.event(.huddleStarted, #"{"ephemeral_channel_id":""}"#, tags: [["h", Self.parent]], at: 1_001),
            // No `h` at all: there is no channel to attribute it to.
            relay.event(.huddleStarted, Self.body, at: 1_002),
        ], phase: .backfill)

        #expect(try await store.strings("SELECT channel_id AS c FROM huddle", column: "c").isEmpty)
    }
}
