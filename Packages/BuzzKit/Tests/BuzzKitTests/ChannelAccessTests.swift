@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("Relay-authoritative channel access")
struct ChannelAccessTests {
    @Test("upgrade seed exposes only the signed-in roster and keeps unrelated public channels hidden")
    func seedsMembershipOnlyVisibility() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()

        let events = [
            try relay.event(.groupMetadata, #"{"name":"Mine"}"#, tags: [["d", "mine"]], at: 10),
            try relay.event(.groupMembers, "", tags: [["d", "mine"], ["p", identity.pubkey]], at: 11),
            try relay.event(.groupMetadata, #"{"name":"Leaked"}"#, tags: [["d", "other"]], at: 12),
            try relay.event(.groupMembers, "", tags: [["d", "other"], ["p", "somebody-else"]], at: 13),
        ]
        try await store.ingest(batch: events, phase: .backfill)

        try await store.seedChannelAccessIfNeeded(identity: identity.pubkey)
        #expect(try store.channelList(selfPubkey: identity.pubkey).map(\.id) == ["mine"])
    }

    @Test("an open channel the relay shows but whose roster does not name you stays off the sidebar")
    func accessWithoutMembershipStaysOffTheSidebar() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()

        try await store.ingest(batch: [
            relay.event(.groupMetadata, #"{"name":"Open"}"#, tags: [["d", "open"]], at: 10),
            relay.event(.groupMembers, "", tags: [["d", "open"], ["p", "somebody-else"]], at: 11),
        ], phase: .backfill)
        // The directory grants *visibility* — which is the browser's business, not the
        // sidebar's. Before the membership test, this row alone put the channel there.
        try await store.markChannelAccess(identity: identity.pubkey, channel: "open", state: .active)

        #expect(try store.channelList(selfPubkey: identity.pubkey).isEmpty)

        // A newer roster naming this identity is what puts it on the sidebar.
        try await store.ingest(batch: [
            relay.event(
                .groupMembers,
                "",
                tags: [["d", "open"], ["p", "somebody-else"], ["p", identity.pubkey]],
                at: 12
            ),
        ], phase: .backfill)
        #expect(try store.channelList(selfPubkey: identity.pubkey).map(\.id) == ["open"])
    }

    @Test("archive hides a channel while retaining metadata, messages, and the watermark")
    func archiveRetainsHistory() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()
        let metadata = try relay.event(
            .groupMetadata,
            #"{"name":"History"}"#,
            tags: [["d", "room"]],
            at: 10
        )
        let roster = try relay.event(
            .groupMembers,
            "",
            tags: [["d", "room"], ["p", identity.pubkey]],
            at: 11
        )
        let message = try identity.message("kept", in: "room", at: 12)
        try await store.ingest(batch: [metadata, roster, message], phase: .backfill)
        try await store.seedChannelAccessIfNeeded(identity: identity.pubkey)

        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(
                events: [metadata, roster],
                states: ["room": .archived]
            ),
            identity: identity.pubkey
        )

        #expect(try store.channelList(selfPubkey: identity.pubkey).isEmpty)
        #expect(try store.timeline(channel: "room").map(\.content) == ["kept"])
        #expect(try await store.rowCount("channel") == 1)

        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(
                events: [metadata, roster],
                states: ["room": .notMember]
            ),
            identity: identity.pubkey
        )
        #expect(try store.channelAccessState(identity: identity.pubkey, channel: "room") == .notMember)

        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(
                events: [metadata, roster],
                states: ["room": .active]
            ),
            identity: identity.pubkey
        )
        #expect(try store.channelList(selfPubkey: identity.pubkey).map(\.id) == ["room"])
    }

    @Test("archived metadata is projected and filters an otherwise active membership")
    func archivedMetadataFiltersActive() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()
        let metadata = try relay.event(
            .groupMetadata,
            #"{"name":"Archived"}"#,
            tags: [["d", "room"], ["archived", "true"]],
            at: 10
        )
        let roster = try relay.event(
            .groupMembers,
            "",
            tags: [["d", "room"], ["p", identity.pubkey]],
            at: 11
        )
        try await store.ingest(batch: [metadata, roster], phase: .backfill)
        try await store.seedChannelAccessIfNeeded(identity: identity.pubkey)

        #expect(try store.channelList(selfPubkey: identity.pubkey).isEmpty)
    }

    @Test("a rejected directory event preserves the last complete access snapshot")
    func invalidSnapshotPreservesLastGood() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()
        let metadata = try relay.event(
            .groupMetadata,
            #"{"name":"Good"}"#,
            tags: [["d", "room"]],
            at: 10
        )
        let roster = try relay.event(
            .groupMembers,
            "",
            tags: [["d", "room"], ["p", identity.pubkey]],
            at: 11
        )
        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [metadata, roster], states: ["room": .active]),
            identity: identity.pubkey
        )
        let tampered = NostrEvent(
            id: metadata.id,
            pubkey: metadata.pubkey,
            createdAt: metadata.createdAt,
            kind: metadata.kind,
            tags: metadata.tags,
            content: #"{"name":"tampered"}"#,
            sig: metadata.sig
        )

        await #expect(throws: ChannelAccessError.self) {
            try await store.applyChannelDirectorySnapshot(
                ChannelDirectorySnapshot(events: [tampered], states: ["room": .archived]),
                identity: identity.pubkey
            )
        }
        #expect(try store.channelAccessState(identity: identity.pubkey, channel: "room") == .active)
    }

    @Test("relay admin state grants archive and owner grants delete")
    func lifecyclePermissions() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let owner = try Fixture()
        let admin = try Fixture()
        try await store.ingest(batch: [
            relay.event(
                .groupAdmins,
                "",
                tags: [
                    ["d", "room"],
                    ["p", owner.pubkey, "owner"],
                    ["p", admin.pubkey, "admin"],
                ],
                at: 10
            ),
        ], phase: .backfill)

        #expect(
            try store.channelLifecyclePermissions(identity: owner.pubkey, channel: "room")
                == ChannelLifecyclePermissions(canArchive: true, canDelete: true)
        )
        #expect(
            try store.channelLifecyclePermissions(identity: admin.pubkey, channel: "room")
                == ChannelLifecyclePermissions(canArchive: true, canDelete: false)
        )
    }

    @Test("a stale directory generation cannot commit over a newer request")
    func staleGenerationCannotCommit() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()
        let metadata = try relay.event(
            .groupMetadata,
            #"{"name":"Room"}"#,
            tags: [["d", "room"]],
            at: 10
        )
        let first = try await store.beginChannelDirectoryRefresh(identity: identity.pubkey)
        let second = try await store.beginChannelDirectoryRefresh(identity: identity.pubkey)

        let staleCommitted = try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [metadata], states: ["room": .archived]),
            identity: identity.pubkey,
            generation: first
        )
        #expect(staleCommitted == false)
        #expect(try store.channelAccessState(identity: identity.pubkey, channel: "room") == nil)

        let newestCommitted = try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [metadata], states: ["room": .active]),
            identity: identity.pubkey,
            generation: second
        )
        #expect(newestCommitted)
        #expect(try store.channelAccessState(identity: identity.pubkey, channel: "room") == .active)
    }

    @Test("directory pagination keeps the same-second id boundary and encodes both cursor fields")
    func compositePagination() async throws {
        let earlierID = String(repeating: "1", count: 64)
        let laterID = String(repeating: "2", count: 64)
        let page = [
            NostrEvent(
                id: laterID,
                pubkey: String(repeating: "a", count: 64),
                createdAt: 1_700_000_000,
                kind: .groupMembers,
                tags: [["d", "later"]],
                content: "",
                sig: String(repeating: "b", count: 128)
            ),
            NostrEvent(
                id: earlierID,
                pubkey: String(repeating: "a", count: 64),
                createdAt: 1_700_000_000,
                kind: .groupMembers,
                tags: [["d", "earlier"]],
                content: "",
                sig: String(repeating: "b", count: 128)
            ),
        ]
        let cursor = try ChannelDirectoryClient.paginationCursor(for: page)
        #expect(cursor == DirectoryCursor(createdAt: 1_700_000_000, id: earlierID))

        let body = try JSONEncoder().encode([
            DirectoryFilter(
                kinds: [.groupMembers],
                tagQueries: ["p": [String(repeating: "c", count: 64)]],
                limit: ChannelDirectoryClient.pageSize,
                cursor: cursor
            ),
        ])
        let filters = try #require(
            try JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        )
        #expect(filters[0]["until"] as? Int == 1_700_000_000)
        #expect(filters[0]["before_id"] as? String == earlierID)
    }

    @Test("a full same-second page advances with the composite cursor and state fetches stay bounded")
    func pagedDirectoryUsesCompositeCursorAndBoundedBatches() async throws {
        let transport = FakeHTTPTransport()
        let signer = InMemorySigner(try PrivateKey())
        let identity = try await signer.publicKey().hex
        let queryURL = URL(string: "https://relay.example.com/query")!
        let client = ChannelDirectoryClient(
            transport: transport,
            queryURL: queryURL,
            signer: signer
        )
        let membershipPage = (0 ..< ChannelDirectoryClient.pageSize).map { index in
            NostrEvent(
                id: String(format: "%064x", index),
                pubkey: String(repeating: "a", count: 64),
                createdAt: 1_700_000_000,
                kind: .groupMembers,
                tags: [["d", "room-\(index)"], ["p", identity]],
                content: "",
                sig: String(repeating: "b", count: 128)
            )
        }
        let pageBody = try JSONEncoder().encode(membershipPage)
        // The visibility snapshot goes first and is answered empty here; pagination is
        // what this test is about.
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: pageBody)
        await transport.enqueue(status: 200, body: "[]")
        // Open-channel discovery, between the membership pages and the state batches.
        // Empty, so the 500 channels under test still come from membership alone and
        // the batching assertions below are about exactly what they were.
        await transport.enqueue(status: 200, body: "[]")
        for _ in 0 ..< 5 {
            await transport.enqueue(status: 200, body: "[]")
        }

        let snapshot = try await client.fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )
        #expect(snapshot.states.count == ChannelDirectoryClient.pageSize)

        let requests = await transport.requests
        // Visibility, two membership pages, discovery, then five bounded state batches.
        #expect(requests.count == 9)
        let secondPage = try #require(
            try JSONSerialization.jsonObject(with: requests[2].body) as? [[String: Any]]
        )
        #expect(secondPage[0]["until"] as? Int == 1_700_000_000)
        #expect(secondPage[0]["before_id"] as? String == String(repeating: "0", count: 64))

        // Request 3 is open-channel discovery; its shape is asserted in
        // ``OpenChannelDiscoveryTests``. Everything after it is a bounded state batch.
        for request in requests.dropFirst(4) {
            let filters = try #require(
                try JSONSerialization.jsonObject(with: request.body) as? [[String: Any]]
            )
            let channels = try #require(filters[0]["#d"] as? [String])
            #expect(channels.count <= ChannelDirectoryClient.channelBatchSize)
        }
    }

    @Test("terminal refusals persist but cannot be retried")
    func terminalOutboxFailureIsNotRetryable() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let entry = try await harness.store.enqueue(
            content: "still visible",
            in: "room",
            tags: [["h", "room"]],
            with: harness.signer
        )
        try await harness.store.markFailed(
            entry.id,
            error: "restricted: membership removed",
            retryable: false
        )

        let failed = try #require(try await harness.store.entry(id: entry.id))
        #expect(failed.isRetryable == false)
        await #expect(throws: OutboxError.notRetryable(entry.id)) {
            try await harness.store.retry(entry.id)
        }
    }

    @Test("archive and delete commands use the relay channel lifecycle kinds and exact tags")
    func lifecycleWireShapes() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: PrivateKey(),
            relays: []
        )

        let archive = try await harness.engine.signLifecycleCommand(
            kind: .groupEditMetadata,
            tags: [["h", "room"], ["archived", "true"]]
        )
        #expect(archive.kind == .groupEditMetadata)
        #expect(archive.tags == [["h", "room"], ["archived", "true"]])
        #expect(archive.kind != .archiveRequest)

        let delete = try await harness.engine.signLifecycleCommand(
            kind: .groupDelete,
            tags: [["h", "room"]]
        )
        #expect(delete.kind == .groupDelete)
        #expect(delete.tags == [["h", "room"]])

        await harness.engine.stop()
    }
}
