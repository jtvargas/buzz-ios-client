@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Cross-device channel mutes: the `kind:30078` `channel-mutes` blob Desktop and the
/// Flutter client already share, and the per-channel last-writer-wins merge that decides
/// what this device believes.
@Suite("Channel mutes", .timeLimit(.minutes(1)))
struct ChannelMuteTests {
    // MARK: - The wire shape, which is not ours to choose

    @Test("the blob is the {version, channels:{muted, updatedAt}} shape the other clients write")
    func blobEncodesTheSharedShape() throws {
        let blob = ChannelMuteBlob(channels: [
            "room-a": ChannelMuteEntry(muted: true, updatedAt: 1700),
            "room-b": ChannelMuteEntry(muted: false, updatedAt: 1800),
        ])
        // Byte-for-byte, because a client that writes a shape of its own making is a
        // client whose mutes only exist on the phone that set them.
        #expect(try blob.encodedJSON() == """
        {"channels":{"room-a":{"muted":true,"updatedAt":1700},\
        "room-b":{"muted":false,"updatedAt":1800}},"version":1}
        """)
    }

    @Test("an unmute survives the round trip as a record, not as an absence")
    func unmuteIsARecord() throws {
        let blob = ChannelMuteBlob(channels: [
            "room-a": ChannelMuteEntry(muted: false, updatedAt: 1800),
        ])
        let decoded = try #require(ChannelMuteBlob.decode(plaintext: blob.encodedJSON()))
        // The whole reason `muted: false` is on the wire: dropping it would let another
        // device's older `true` win the next time the two blobs meet.
        #expect(decoded.channels["room-a"] == ChannelMuteEntry(muted: false, updatedAt: 1800))
    }

    @Test("one malformed channel entry does not cost the reader the rest of the blob")
    func partialTolerance() {
        let plaintext = """
        {"version":1,"channels":{"good":{"muted":true,"updatedAt":10},\
        "no-stamp":{"muted":true},"not-an-object":7,"":{"muted":true,"updatedAt":9}}}
        """
        let decoded = ChannelMuteBlob.decode(plaintext: plaintext)
        #expect(decoded?.channels.keys.sorted() == ["good"])
    }

    @Test("an unreadable envelope is nil rather than an empty table")
    func brokenEnvelopeIsNil() {
        // The difference matters: an empty table adopted as truth would republish every
        // mute this identity holds as deleted.
        #expect(ChannelMuteBlob.decode(plaintext: "not json") == nil)
        #expect(ChannelMuteBlob.decode(plaintext: #"{"version":1}"#) == nil)
    }

    // MARK: - Telling the two kind:30078 events apart

    @Test("the tag gate accepts a mute blob and refuses read state on the same kind")
    func tagGateSeparatesTheTwoAppDataEvents() throws {
        let author = try Fixture()
        let mutes = try author.event(.readState, "x", tags: [
            ChannelMutes.dTag(), ChannelMutes.tTag(),
        ], at: 100)
        #expect(ChannelMutes.hasValidTags(mutes))

        // Read state shares the kind and is a *different addressable event*. If this ever
        // passes, one feature's blob replaces the other's at the relay.
        let readState = try author.event(.readState, "x", tags: [
            ["d", "read-state:slot-1"], ["t", "read-state"],
        ], at: 100)
        #expect(!ChannelMutes.hasValidTags(readState))

        // A second `d` tag makes the coordinate ambiguous, so the event is not ours.
        let twoCoordinates = try author.event(.readState, "x", tags: [
            ChannelMutes.dTag(), ["d", "something-else"], ChannelMutes.tTag(),
        ], at: 100)
        #expect(!ChannelMutes.hasValidTags(twoCoordinates))
    }

    @Test("the global REQ carries a mute filter of its own, disjoint from read state's")
    func mutesRideTheGlobalREQAsTheirOwnFilter() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()
        let harness = try EngineHarness(path: database.path, identity: identity, relays: [socket])

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        let filters = await globalFilters(on: socket)
        let mutes = try #require(filters.first { $0.tagQueries["t"] == [ChannelMutes.tTagValue] })
        #expect(mutes.kinds == [.readState])
        #expect(mutes.authors == [identity.publicKey.hex])
        // A NIP-01 filter ANDs its tag queries, so one filter asking for both `t` values
        // would match an event carrying *both* — which is nothing. Two filters, always:
        // read state's is still there and still asks for its own `t`.
        #expect(mutes.tagQueries["d"] == nil)
        #expect(filters.contains { $0.tagQueries["t"] == ["read-state"] })
        // `#h`-less, like every other filter on the global REQ: a mute is channel-less
        // user state and the relay fans it out globally.
        #expect(mutes.tagQueries["h"] == nil)
    }

    /// The filters of the global REQ — the one carrying the membership filter.
    private func globalFilters(on relay: ScriptedRelay) async -> [Filter] {
        while true {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame), membershipFilter(in: request.filters) != nil {
                    return request.filters
                }
            }
            await Task.yield()
        }
    }

    // MARK: - The merge

    @Test("a newer entry wins per channel, an older one is ignored, and neither is wholesale")
    func perChannelLastWriterWins() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await store.setChannelMute("room-a", muted: true, updatedAt: 1000)
        try await store.setChannelMute("room-b", muted: true, updatedAt: 1000)

        // One blob, carrying a newer opinion about `room-a` and a staler one about
        // `room-b`. A wholesale replace would take both; the per-entry stamps take one.
        let changed = try await store.applyChannelMutes([
            "room-a": ChannelMuteEntry(muted: false, updatedAt: 2000),
            "room-b": ChannelMuteEntry(muted: false, updatedAt: 500),
        ], sourceCreatedAt: 2000, sourceEventID: "evt-1")

        #expect(changed)
        #expect(try store.isChannelMuted("room-a") == false)
        #expect(try store.isChannelMuted("room-b") == true)
    }

    @Test("an older blob can still carry a newer entry, so it is merged rather than rejected")
    func olderBlobNewerEntry() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await store.applyChannelMutes(
            ["room-a": ChannelMuteEntry(muted: false, updatedAt: 1000)],
            sourceCreatedAt: 5000,
            sourceEventID: "newer-event"
        )
        // A phone that was offline publishes last while holding a *newer* decision. The
        // `(created_at)` cursor guards the cursor, never the merge.
        try await store.applyChannelMutes(
            ["room-a": ChannelMuteEntry(muted: true, updatedAt: 4000)],
            sourceCreatedAt: 4000,
            sourceEventID: "older-event"
        )
        #expect(try store.isChannelMuted("room-a"))

        // …and the cursor did not move backwards, so the next publish still clears the bar.
        let state = try await store.channelMuteState()
        #expect(state.sourceCreatedAt == 5000)
    }

    @Test("a replay reports no change, so two devices cannot republish at each other for ever")
    func replayIsNotAChange() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let incoming = ["room-a": ChannelMuteEntry(muted: true, updatedAt: 1000)]
        #expect(try await store.applyChannelMutes(incoming, sourceCreatedAt: 1000, sourceEventID: "e1"))
        // The relay replays the latest addressable on every reconnect.
        #expect(try await store.applyChannelMutes(incoming, sourceCreatedAt: 1000, sourceEventID: "e1") == false)

        // A newer stamp saying the same thing is stored — it keeps the next comparison
        // honest — but is still not news.
        #expect(try await store.applyChannelMutes(
            ["room-a": ChannelMuteEntry(muted: true, updatedAt: 3000)],
            sourceCreatedAt: 3000,
            sourceEventID: "e2"
        ) == false)
        let state = try await store.channelMuteState()
        #expect(state.entries["room-a"]?.updatedAt == 3000)
    }

    // MARK: - What the sidebar reads

    @Test("a channel unmuted after being muted does not read as muted for ever")
    func unmutedChannelIsNotMuted() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMetadata, "", tags: [["d", "room-a"], ["name", "Room A"]], at: 900),
        ], phase: .backfill)

        try await store.setChannelMute("room-a", muted: true, updatedAt: 1000)
        #expect(try store.channelList().first { $0.id == "room-a" }?.isMuted == true)

        // The row stays behind with `muted = 0`, which is exactly what an `EXISTS` on the
        // channel id alone would have read as "muted" for ever.
        try await store.setChannelMute("room-a", muted: false, updatedAt: 2000)
        #expect(try store.channelList().first { $0.id == "room-a" }?.isMuted == false)
        #expect(try store.mutedChannelIDs().isEmpty)
    }

    @Test("mute does not touch the unread count it hides")
    func muteIsNotAboutWhatYouHaveRead() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()
        let selfKey = try PrivateKey()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMetadata, "", tags: [["d", "room-a"], ["name", "Room A"]], at: 900),
            try author.message("hello", in: "room-a", at: 1000),
        ], phase: .backfill)
        try await store.markChannelAccess(
            identity: selfKey.publicKey.hex,
            channel: "room-a",
            state: .active
        )
        try await store.seedMembershipForTest(channel: "room-a", members: [selfKey.publicKey.hex])

        try await store.setChannelMute("room-a", muted: true, updatedAt: 1100)
        let row = try #require(
            try store.channelList(selfPubkey: selfKey.publicKey.hex).first { $0.id == "room-a" }
        )
        // Carried beside the count, never folded into it: a muted channel still *has*
        // unread messages, and the row still has to sort by them.
        #expect(row.isMuted)
        #expect(row.unreadCount == 1)
    }
}

/// The relay's three prose fields, which have always been on the wire and which this
/// client kept only one of — showing the *description* under a heading reading Topic.
@Suite("Channel context", .timeLimit(.minutes(1)))
struct ChannelContextTests {
    @Test("description, topic and purpose are projected as the three different things they are")
    func threeFieldsAreThreeColumns() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMetadata, "", tags: [
                ["d", "room-a"],
                ["name", "Room A"],
                ["about", "the description"],
                ["topic", "what we are on right now"],
                ["purpose", "why this room exists"],
            ], at: 900),
        ], phase: .backfill)

        let context = try store.channelContext("room-a")
        #expect(context.description == "the description")
        #expect(context.topic == "what we are on right now")
        #expect(context.purpose == "why this room exists")
        #expect(!context.isEmpty)
    }

    @Test("a channel that has said nothing about itself reads as empty rather than as three blanks")
    func emptyContext() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            // `about` present but blank, which is what the create sheet writes when the
            // description field is left alone.
            try relay.event(.groupMetadata, "", tags: [
                ["d", "room-a"], ["name", "Room A"], ["about", "   "],
            ], at: 900),
        ], phase: .backfill)

        let context = try store.channelContext("room-a")
        #expect(context.isEmpty, "a sheet with three “Not set” cards is worse than no section")
        #expect(context.topic == nil)
        #expect(context.purpose == nil)
    }

    @Test("a channel with no metadata at all still answers, rather than throwing")
    func unknownChannel() throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        #expect(try store.channelContext("never-heard-of-it").isEmpty)
    }
}
