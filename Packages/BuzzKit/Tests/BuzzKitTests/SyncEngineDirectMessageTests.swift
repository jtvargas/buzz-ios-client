@testable import BuzzKit
import Foundation
import NostrCore
import Testing

// MARK: - Test support

/// A started, authenticated engine on a fresh on-disk store with discovery already
/// answered empty — the state every DM-open test begins from. The caller owns
/// `remove()` and `stop()`.
private func startedEngine(_ label: String) async throws -> (EngineHarness, ScriptedRelay) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("dmopen-\(label)-\(UUID().uuidString).sqlite").path
    let socket = ScriptedRelay()
    let harness = try EngineHarness(path: path, identity: try PrivateKey(), relays: [socket])
    try await harness.engine.start()
    try await driveAuth(harness.connection, socket)
    await answerDiscovery(on: socket)
    await waitUntil { await harness.engine.state == .running }
    return (harness, socket)
}

/// The relay's command answer for an open: the literal `response:` prefix, then JSON.
private func openResponse(channelID: String, created: Bool) -> String {
    #"response:{"channel_id":"\#(channelID)","created":\#(created)}"#
}

/// The DM read-back REQ: the 39000 and 39002 shapes, each a single-kind filter
/// `#d`-scoped to the channel with `limit: 1`, riding one REQ.
///
/// The exact shapes are what discriminate it from the two other group-state queries
/// on the wire — the on-ready discovery REQ (three kinds, no `#d`, no limit) and
/// `rediscoverAndReconcile`'s refetch (three kinds in one filter, `#d`, no limit).
private func isDirectMessageReadBackREQ(_ filters: [Filter], channel: String) -> Bool {
    func hasShape(_ kind: EventKind) -> Bool {
        filters.contains { $0.kinds == [kind] && $0.limit == 1 && $0.tagQueries["d"] == [channel] }
    }
    return hasShape(.groupMetadata) && hasShape(.groupMembers)
}

/// Answers the read-back REQ with `events` then EOSE. The open awaits this, so it is
/// what lets the call return.
private func answerReadBack(on relay: ScriptedRelay, channel: String, events: [NostrEvent] = []) async {
    let id = await awaitREQ(on: relay) { isDirectMessageReadBackREQ($0, channel: channel) }
    for event in events { await relay.enqueue(EngineFrames.event(id, event)) }
    await relay.enqueue(EngineFrames.eose(id))
}

/// Gives any errant extra publish time to appear before a "no retry" assertion.
private func settle() async {
    for _ in 0 ..< 40 { await Task.yield() }
}

// MARK: - The command on the wire

/// Opening a DM: one kind-41010 command whose `OK` message carries the channel id,
/// the three failure modes it must survive, and the read-back that makes the channel
/// exist locally.
@Suite("SyncEngine.openDirectMessage", .timeLimit(.minutes(1)))
struct SyncEngineDirectMessageTests {
    @Test("the command carries kind 41010, one lowercased `p` tag, a nonce, and no `d` tag")
    func commandShape() async throws {
        let (harness, socket) = try await startedEngine("shape")
        defer { harness.remove() }

        // Upper-cased on the way in: the tag must still be the lowercase 64-hex the
        // relay hashes the participant set from.
        let peer = try PrivateKey().publicKey.hex
        let open = Task { try await harness.engine.openDirectMessage(with: peer.uppercased()) }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.kind == .directMessageOpen)
        #expect(command.content.isEmpty)
        #expect(command.allValues(forTag: "p") == [peer])
        #expect(command.pubkey == harness.selfPubkey)
        // Self is merged in and deduped relay-side, so tagging it would only spend one
        // of the eight allowed participant slots.
        #expect(!command.allValues(forTag: "p").contains(harness.selfPubkey))
        #expect(command.firstValue(forTag: "nonce")?.isEmpty == false)
        // A `d` tag on a command kind activates NIP-33 replace semantics, and the
        // relay then answers `Duplicate` with no payload at all.
        #expect(command.addressableIdentifier == nil)
        #expect(command.tags.compactMap(\.first).sorted() == ["nonce", "p"])

        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-shape", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-shape")
        #expect(try await open.value == "dm-shape")

        await harness.engine.stop()
    }

    @Test("a create resolves to the new channel id and reads the channel into the store")
    func createResolvesAndReadsBack() async throws {
        let (harness, socket) = try await startedEngine("create")
        defer { harness.remove() }
        let fixtures = try EngineFixtures()

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-01", created: true))
        )

        // 39000/39002 are stored channel-scoped and never fan out to the `#h`-less
        // global REQ, so this explicit historical read-back is the only thing that puts
        // the channel in the store at open time.
        await answerReadBack(
            on: socket,
            channel: "dm-01",
            events: [try fixtures.metadata(for: "dm-01", name: "DM")]
        )

        #expect(try await open.value == DirectMessageOpen(channelID: "dm-01", wasCreated: true))
        #expect(try await harness.store.knownChannels().contains("dm-01"))
        // The standing per-channel content sub is open before the call returns, so the
        // DM the user is about to look at is already receiving live traffic.
        _ = await awaitChannelContentREQ(on: socket, channel: "dm-01")

        await harness.engine.stop()
    }

    @Test("`created: false` is the success path — the DM already existed")
    func openExistingIsSuccess() async throws {
        let (harness, socket) = try await startedEngine("existing")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-existing", created: false))
        )
        // A re-open republishes no 39000/39002 at all, so the read-back legitimately
        // comes back empty — and the open must still succeed.
        await answerReadBack(on: socket, channel: "dm-existing")

        #expect(try await open.value == DirectMessageOpen(channelID: "dm-existing", wasCreated: false))
        #expect(await publishedEvents(on: socket).count == 1)

        await harness.engine.stop()
    }

    @Test("a same-second duplicate event id drives a re-sign with a fresh nonce")
    func duplicateEventIDResigns() async throws {
        let (harness, socket) = try await startedEngine("dupe")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }

        // The relay recognised the event id and did nothing: accepted, but with no
        // payload. This is the reference client's bug — it throws here.
        let first = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(first.id, true, "duplicate: already processed"))

        let second = await awaitPublishedEvent(on: socket, excluding: [first.id])
        // The engine's clock is pinned, so both attempts share a `created_at` — exactly
        // the same-second collision the nonce exists to break. Everything else that
        // feeds the id hash is identical, so the fresh nonce is the *only* reason the
        // second attempt is a distinct event.
        #expect(second.createdAt == first.createdAt)
        #expect(second.firstValue(forTag: "p") == first.firstValue(forTag: "p"))
        #expect(second.firstValue(forTag: "nonce") != first.firstValue(forTag: "nonce"))
        #expect(second.id != first.id)

        await socket.enqueue(
            EngineFrames.okEncoding(second.id, true, openResponse(channelID: "dm-resign", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-resign")

        #expect(try await open.value == DirectMessageOpen(channelID: "dm-resign", wasCreated: true))
        await harness.engine.stop()
    }

    @Test("a relay internal error is retried once and takes the existing-DM fast path")
    func internalErrorRetriesOnce() async throws {
        let (harness, socket) = try await startedEngine("race")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }

        // Two devices raced the first create; one lost on a unique index and the relay
        // has no retry of its own. The one retry finds the winner's row.
        let first = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(first.id, false, "error: internal server error"))

        let second = await awaitPublishedEvent(on: socket, excluding: [first.id])
        await socket.enqueue(
            EngineFrames.okEncoding(second.id, true, openResponse(channelID: "dm-race", created: false))
        )
        await answerReadBack(on: socket, channel: "dm-race")

        #expect(try await open.value == DirectMessageOpen(channelID: "dm-race", wasCreated: false))
        #expect(await publishedEvents(on: socket).count == 2)
        await harness.engine.stop()
    }

    @Test("a second internal error surfaces the typed reason rather than retrying again")
    func internalErrorRetriesOnlyOnce() async throws {
        let (harness, socket) = try await startedEngine("race-twice")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }
        let first = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(first.id, false, "error: internal server error"))
        let second = await awaitPublishedEvent(on: socket, excluding: [first.id])
        await socket.enqueue(EngineFrames.ok(second.id, false, "error: internal server error"))

        await #expect(throws: DirectMessageError.rejected(.error("internal server error"))) {
            _ = try await open.value
        }
        await settle()
        #expect(await publishedEvents(on: socket).count == 2)
        await harness.engine.stop()
    }

    @Test("an `invalid:` rejection is typed and never retried")
    func invalidIsTerminal() async throws {
        let (harness, socket) = try await startedEngine("invalid")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(command.id, false, "invalid: too many participants"))

        await #expect(throws: DirectMessageError.rejected(.invalid("too many participants"))) {
            _ = try await open.value
        }
        // The whole point of terminal: resending an identical command earns an
        // identical refusal, so exactly one attempt reached the wire.
        await settle()
        #expect(await publishedEvents(on: socket).count == 1)
        await harness.engine.stop()
    }

    @Test("a `restricted:` rejection is typed and never retried")
    func restrictedIsTerminal() async throws {
        let (harness, socket) = try await startedEngine("restricted")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(command.id, false, "restricted: not a relay member"))

        await #expect(throws: DirectMessageError.rejected(.restricted("not a relay member"))) {
            _ = try await open.value
        }
        await settle()
        #expect(await publishedEvents(on: socket).count == 1)
        await harness.engine.stop()
    }

    @Test("an accepted command whose message is not a `response:` payload is typed, not retried")
    func acceptedWithoutPayloadIsMalformed() async throws {
        let (harness, socket) = try await startedEngine("no-payload")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(command.id, true, "stored"))

        await #expect(throws: DirectMessageError.malformedResponse("stored")) {
            _ = try await open.value
        }
        await settle()
        #expect(await publishedEvents(on: socket).count == 1)
        await harness.engine.stop()
    }

    @Test("unrelenting duplicate answers exhaust the re-sign budget and report it")
    func duplicateBudgetIsBounded() async throws {
        let (harness, socket) = try await startedEngine("dupe-forever")
        defer { harness.remove() }

        let open = Task {
            try await harness.engine.openOrCreateDirectMessage(with: try PrivateKey().publicKey.hex)
        }

        // One initial attempt plus `maxNonceResigns` re-signs, each a distinct event.
        var seen: Set<String> = []
        for _ in 0 ... SyncEngine.maxNonceResigns {
            let attempt = await awaitPublishedEvent(on: socket, excluding: seen)
            seen.insert(attempt.id)
            await socket.enqueue(EngineFrames.ok(attempt.id, true, "duplicate: already processed"))
        }

        let attempts = SyncEngine.maxNonceResigns + 1
        await #expect(throws: DirectMessageError.duplicateEventIDUnresolved(attempts: attempts)) {
            _ = try await open.value
        }
        await settle()
        #expect(seen.count == attempts)
        #expect(await publishedEvents(on: socket).count == attempts)
        await harness.engine.stop()
    }

    @Test("an unusable peer identifier fails before anything reaches the wire")
    func invalidPeerNeverPublishes() async throws {
        let (harness, socket) = try await startedEngine("bad-peer")
        defer { harness.remove() }

        await #expect(throws: DirectMessageError.invalidPeerPubkey("not-a-pubkey")) {
            _ = try await harness.engine.openDirectMessage(with: "not-a-pubkey")
        }
        await settle()
        #expect(await publishedEvents(on: socket).isEmpty)
        await harness.engine.stop()
    }
}

// MARK: - Several people at once

/// The same command with a longer participant set. What is tested here is the set the
/// client sends: one `p` tag per person, what it drops before counting, and the two
/// refusals it makes without a round trip.
@Suite("SyncEngine.openDirectMessage(with peers:)", .timeLimit(.minutes(1)))
struct SyncEngineGroupDirectMessageTests {
    /// Distinct peers, lowercase 64-hex, stable within a call.
    private func peers(_ count: Int) throws -> [String] {
        try (0 ..< count).map { _ in try PrivateKey().publicKey.hex }
    }

    @Test("every peer gets its own `p` tag, in the order given, and the nonce comes last")
    func tagPerPeerInOrder() async throws {
        let (harness, socket) = try await startedEngine("group-shape")
        defer { harness.remove() }

        let people = try peers(3)
        let open = Task { try await harness.engine.openDirectMessage(with: people) }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.kind == .directMessageOpen)
        #expect(command.allValues(forTag: "p") == people)
        // Self is merged in relay-side; tagging it would spend one of the eight slots.
        #expect(!command.allValues(forTag: "p").contains(harness.selfPubkey))
        #expect(command.tags.compactMap(\.first) == ["p", "p", "p", "nonce"])
        #expect(command.addressableIdentifier == nil)

        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-group", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-group")
        #expect(try await open.value == "dm-group")

        await harness.engine.stop()
    }

    @Test("hex and `npub1…` may be mixed in one call and both land as lowercase hex")
    func mixedIdentifierFormsNormalize() async throws {
        let (harness, socket) = try await startedEngine("group-npub")
        defer { harness.remove() }

        let first = try PrivateKey().publicKey
        let second = try PrivateKey().publicKey
        let open = Task {
            try await harness.engine.openDirectMessage(with: [first.hex.uppercased(), second.npub])
        }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.allValues(forTag: "p") == [first.hex, second.hex])

        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-npub", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-npub")
        #expect(try await open.value == "dm-npub")

        await harness.engine.stop()
    }

    @Test("a repeated person is sent once, keeping the position they were first given")
    func repeatsAreDropped() async throws {
        let (harness, socket) = try await startedEngine("group-dupe-peer")
        defer { harness.remove() }

        let people = try peers(2)
        let open = Task {
            // The same person three ways: as given, upper-cased, and with whitespace.
            try await harness.engine.openDirectMessage(
                with: [people[0], people[1], people[0].uppercased(), " \(people[0]) "]
            )
        }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.allValues(forTag: "p") == people)

        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-dedupe", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-dedupe")
        #expect(try await open.value == "dm-dedupe")

        await harness.engine.stop()
    }

    @Test("this identity is dropped from the set rather than spending a slot")
    func selfIsDropped() async throws {
        let (harness, socket) = try await startedEngine("group-self")
        defer { harness.remove() }

        let people = try peers(2)
        let open = Task {
            try await harness.engine.openDirectMessage(with: [people[0], harness.selfPubkey, people[1]])
        }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.allValues(forTag: "p") == people)

        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-self", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-self")
        #expect(try await open.value == "dm-self")

        await harness.engine.stop()
    }

    @Test("the cap counts distinct other people, so it is reached only after deduping")
    func capIsCheckedAfterDeduping() async throws {
        let (harness, socket) = try await startedEngine("group-cap-dedupe")
        defer { harness.remove() }

        // Nine identifiers, eight distinct people: over the cap as written, at it as
        // counted. The relay would refuse this list on length; the client must not.
        let people = try peers(SyncEngine.maxDirectMessagePeers)
        let open = Task { try await harness.engine.openDirectMessage(with: people + [people[0]]) }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.allValues(forTag: "p").count == SyncEngine.maxDirectMessagePeers)

        await socket.enqueue(
            EngineFrames.okEncoding(command.id, true, openResponse(channelID: "dm-cap", created: true))
        )
        await answerReadBack(on: socket, channel: "dm-cap")
        #expect(try await open.value == "dm-cap")

        await harness.engine.stop()
    }

    @Test("a ninth distinct person is refused here, without a round trip")
    func overCapNeverPublishes() async throws {
        let (harness, socket) = try await startedEngine("group-over-cap")
        defer { harness.remove() }

        let limit = SyncEngine.maxDirectMessagePeers
        let people = try peers(limit + 1)
        // The relay's own words for this, verified live: `pubkeys may contain at most 8
        // other participants (9 total)`. Caught before the wire so a picker never has to
        // show it.
        await #expect(throws: DirectMessageError.tooManyPeers(count: limit + 1, limit: limit)) {
            _ = try await harness.engine.openDirectMessage(with: people)
        }
        await settle()
        #expect(await publishedEvents(on: socket).isEmpty)

        await harness.engine.stop()
    }

    @Test("an empty set, or one naming only this identity, is `noPeers` and never published")
    func emptySetNeverPublishes() async throws {
        let (harness, socket) = try await startedEngine("group-empty")
        defer { harness.remove() }

        await #expect(throws: DirectMessageError.noPeers) {
            _ = try await harness.engine.openDirectMessage(with: [])
        }
        // Well-formed input naming nobody else: not `invalidPeerPubkey`, because there
        // is nothing wrong with the identifier.
        await #expect(throws: DirectMessageError.noPeers) {
            _ = try await harness.engine.openDirectMessage(with: [harness.selfPubkey])
        }
        await settle()
        #expect(await publishedEvents(on: socket).isEmpty)

        await harness.engine.stop()
    }

    @Test("one bad identifier fails the whole call, even beside good ones")
    func oneBadIdentifierFailsTheCall() async throws {
        let (harness, socket) = try await startedEngine("group-bad-peer")
        defer { harness.remove() }

        let good = try PrivateKey().publicKey.hex
        await #expect(throws: DirectMessageError.invalidPeerPubkey("not-a-pubkey")) {
            _ = try await harness.engine.openDirectMessage(with: [good, "not-a-pubkey"])
        }
        await settle()
        #expect(await publishedEvents(on: socket).isEmpty)

        await harness.engine.stop()
    }
}
