@testable import BuzzKit
import Foundation
import NostrCore
import Testing

// MARK: - Test support

/// A started, authenticated engine on a fresh on-disk store with discovery answered
/// empty. The caller owns `remove()` and `stop()`.
private func startedEngine(_ label: String) async throws -> (EngineHarness, ScriptedRelay) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("dmhide-\(label)-\(UUID().uuidString).sqlite").path
    let socket = ScriptedRelay()
    let harness = try EngineHarness(path: path, identity: try PrivateKey(), relays: [socket])
    try await harness.engine.start()
    try await driveAuth(harness.connection, socket)
    await answerDiscovery(on: socket)
    await waitUntil { await harness.engine.state == .running }
    return (harness, socket)
}

/// Puts `channel` in the store as an ordinary active conversation with one message in
/// it, which is the state a DM is in when its row is long-pressed.
private func seedActiveChannel(
    _ channel: String,
    in harness: EngineHarness
) async throws {
    let fixtures = try EngineFixtures()
    _ = try await harness.store.ingest(
        batch: [
            try fixtures.metadata(for: channel, name: "Someone"),
            try fixtures.message("hello", in: channel, at: 1_700_000_100),
        ],
        phase: .backfill
    )
    try await harness.store.markChannelAccess(
        identity: harness.selfPubkey,
        channel: channel,
        state: .active
    )
}

// MARK: - The command on the wire

/// Hiding a DM: one kind-41012 command, and what the local store is allowed to believe
/// on each side of the relay's verdict.
///
/// The read half of this loop — the relay's kind-30622 snapshot, and every way it can
/// fail — is covered by ``DirectMessageVisibilityTests``. What is here is only the
/// write: the event's shape, and the rule that a *refused* hide changes nothing, since
/// a local demotion the relay never agreed to is a conversation the reader cannot see
/// and cannot get back.
@Suite("SyncEngine.hideDirectMessage", .timeLimit(.minutes(1)))
struct SyncEngineDirectMessageHideTests {
    @Test("the command carries kind 41012, one `h` tag naming the DM, a nonce, and no `d` tag")
    func commandShape() async throws {
        let (harness, socket) = try await startedEngine("shape")
        defer { harness.remove() }
        try await seedActiveChannel("dm-shape", in: harness)

        let hide = Task { try await harness.engine.hideDirectMessage("dm-shape") }

        let command = await awaitPublishedEvent(on: socket)
        #expect(command.kind == .directMessageHide)
        #expect(command.content.isEmpty)
        #expect(command.allValues(forTag: "h") == ["dm-shape"])
        #expect(command.pubkey == harness.selfPubkey)
        #expect(command.firstValue(forTag: "nonce")?.isEmpty == false)
        // A `d` tag on a command kind activates NIP-33 replace semantics, and the relay
        // then answers `Duplicate` having executed nothing — the same trap the open
        // command documents.
        #expect(command.addressableIdentifier == nil)
        #expect(command.tags.compactMap(\.first).sorted() == ["h", "nonce"])

        await socket.enqueue(EngineFrames.ok(command.id, true, "{}"))
        try await hide.value

        await harness.engine.stop()
    }

    @Test("an accepted hide takes the DM off the sidebar and leaves its history alone")
    func acceptedHideDemotes() async throws {
        let (harness, socket) = try await startedEngine("accept")
        defer { harness.remove() }
        try await seedActiveChannel("dm-accept", in: harness)
        #expect(try await harness.store.activeChannelIDs(identity: harness.selfPubkey) == ["dm-accept"])

        let hide = Task { try await harness.engine.hideDirectMessage("dm-accept") }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(command.id, true, "{}"))
        try await hide.value

        let identity = harness.selfPubkey
        #expect(try harness.store.channelAccessState(identity: identity, channel: "dm-accept") == .hidden)
        // The two reads that decide what the sidebar draws and what the next directory
        // pass re-checks. Hiding is not leaving, so it must stay in the second: a hidden
        // DM whose membership later changes has to be able to reach `.notMember` rather
        // than sit hidden forever.
        #expect(try await harness.store.activeChannelIDs(identity: identity).isEmpty)
        #expect(try await harness.store.previouslyActiveChannelIDs(identity: identity) == ["dm-accept"])
        // Presentation, not deletion: the conversation and its messages are untouched.
        #expect(try await harness.store.knownChannels().contains("dm-accept"))
        #expect(try harness.store.timeline(channel: "dm-accept").count == 1)

        await harness.engine.stop()
    }

    @Test("a hidden DM is still writable, because hiding is not leaving")
    func hiddenStaysWritable() async throws {
        let (harness, socket) = try await startedEngine("writable")
        defer { harness.remove() }
        try await seedActiveChannel("dm-writable", in: harness)

        let hide = Task { try await harness.engine.hideDirectMessage("dm-writable") }
        let command = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(command.id, true, "{}"))
        try await hide.value

        let state = try harness.store.channelAccessState(
            identity: harness.selfPubkey,
            channel: "dm-writable"
        )
        #expect(state?.isWritable == true)

        await harness.engine.stop()
    }

    @Test("a refused hide throws the relay's own reason and demotes nothing")
    func refusedHideChangesNothing() async throws {
        let (harness, socket) = try await startedEngine("refuse")
        defer { harness.remove() }
        try await seedActiveChannel("dm-refuse", in: harness)

        let hide = Task { try await harness.engine.hideDirectMessage("dm-refuse") }
        let command = await awaitPublishedEvent(on: socket)
        // What a two-person *channel* earns: the sidebar calls a conversation direct when
        // its roster is two people, and only the relay knows whether it is really a DM.
        await socket.enqueue(EngineFrames.ok(command.id, false, "invalid: channel is not a DM"))

        await #expect(throws: DirectMessageError.rejected(.invalid("channel is not a DM"))) {
            try await hide.value
        }

        // The whole point of demoting *after* the verdict rather than optimistically: a
        // row taken off the sidebar for a hide the relay refused is a conversation the
        // reader can neither see nor get back.
        let identity = harness.selfPubkey
        #expect(try harness.store.channelAccessState(identity: identity, channel: "dm-refuse") == .active)
        #expect(try await harness.store.activeChannelIDs(identity: identity) == ["dm-refuse"])

        await harness.engine.stop()
    }

    @Test("two hides of one DM inside a second are two distinct events")
    func nonceMakesEachAttemptDistinct() async throws {
        let (harness, socket) = try await startedEngine("nonce")
        defer { harness.remove() }
        try await seedActiveChannel("dm-nonce", in: harness)

        // The sequence this guards is real: hide, re-open (which clears the hide relay-side),
        // hide again. Without a fresh id per attempt the second command hashes to the first
        // — same author, second, kind, tags, content — and the relay's id dedupe answers it
        // `duplicate: already processed` having executed nothing, so the DM stays visible.
        let first = Task { try await harness.engine.hideDirectMessage("dm-nonce") }
        let one = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(one.id, true, "{}"))
        try await first.value

        let second = Task { try await harness.engine.hideDirectMessage("dm-nonce") }
        let two = await awaitPublishedEvent(on: socket, excluding: [one.id])
        await socket.enqueue(EngineFrames.ok(two.id, true, "{}"))
        try await second.value

        #expect(one.id != two.id)
        #expect(one.firstValue(forTag: "nonce") != two.firstValue(forTag: "nonce"))
        // Everything the id is otherwise hashed from is identical, which is what makes the
        // nonce the only thing separating them.
        #expect(one.createdAt == two.createdAt)
        #expect(one.allValues(forTag: "h") == two.allValues(forTag: "h"))

        await harness.engine.stop()
    }
}
