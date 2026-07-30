@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The hidden-DM loop against a real relay.
///
/// Everything the deterministic suite can prove is that *given* a kind-30622 snapshot
/// shaped like the spec, the directory demotes the DMs it names. Three things it
/// cannot prove, and all three are the relay's half of the contract:
///
/// 1. That `POST /query` accepts `kinds:[30622], #p:[self]` at all rather than
///    refusing it — the read gate is deliberately strict about this kind, and a
///    refusal is absorbed silently by design, so a wrong filter shape would look
///    exactly like "nothing is hidden".
/// 2. That hiding a DM (kind 41012) actually causes a fresh snapshot to be published.
///    It is a best-effort post-commit side effect, not part of the command's own
///    transaction.
/// 3. That re-opening the DM (kind 41010) clears the hide, which is the only way back
///    — there is no unhide command.
///
/// Disabled unless `BUZZKIT_INTEGRATION_URL` names a relay, so `make test` and CI
/// never touch the network.
///
/// Run:
/// `BUZZKIT_INTEGRATION_URL=wss://homelab.tail4bc643.ts.net swift test -c release \
///   --package-path Packages/BuzzKit --filter LiveDirectMessageVisibility`
@Suite(
    "Live hidden direct messages",
    .enabled(if: LiveRelay.enabled),
    .serialized,
    .timeLimit(.minutes(5))
)
struct LiveDirectMessageVisibilityTests {
    @Test("hiding a DM demotes it out of the directory, and re-opening it brings it back")
    func hideAndReopenRoundTrip() async throws {
        // Throwaway on both sides: a DM between two keys nobody else holds cannot
        // appear in anyone's real sidebar, and it ends the test hidden either way.
        let signer = try InMemorySigner()
        let peerHex = try await InMemorySigner().publicKey().hex
        let database = TempDatabase()
        defer { database.remove() }

        guard let live = try await LiveDirectMessageProbe.start(
            store: try database.open(),
            signer: signer,
            peer: peerHex
        ) else { return }
        defer { Task { await live.stop() } }

        print("[LIVE] DM opened: \(live.channel)")
        var state = await live.state()
        print("[LIVE] state after open: \(state.map(\.rawValue) ?? "nil")")
        #expect(state == .active)

        guard await live.hide() else { return }
        let becameHidden = await live.waitFor(.hidden)
        state = await live.state()
        print("[LIVE] state after hide: \(state.map(\.rawValue) ?? "nil")")
        #expect(becameHidden, "the relay never published a visibility snapshot naming the hidden DM")

        // Membership is untouched by a hide — that is the whole reason this fix needs a
        // second query, so it is worth asserting rather than assuming.
        #expect(await live.rosterStillNamesMe())

        // There is no unhide command: re-opening the DM is the way back, and the relay
        // clears `hidden_at` on the existing-DM branch of kind 41010.
        _ = try await live.engine.openDirectMessage(with: peerHex)
        let cameBack = await live.waitFor(.active)
        state = await live.state()
        print("[LIVE] state after re-open: \(state.map(\.rawValue) ?? "nil")")
        #expect(cameBack, "re-opening the DM did not clear the hide")

        // Leave it hidden so the throwaway DM is off both sidebars.
        _ = await live.hide()
    }
}

/// One live DM plus the authenticated directory client that reads its access state,
/// so the test above reads as the sequence of relay facts it is asserting.
private struct LiveDirectMessageProbe: Sendable {
    let engine: SyncEngine
    let connection: RelayConnection
    let directory: ChannelDirectoryClient
    let signer: InMemorySigner
    let identity: String
    let channel: String

    /// Starts an engine, opens a DM with `peer`, and returns the probe — or `nil`
    /// (having recorded the finding and stopped the engine) if the relay never came up,
    /// which is a live-environment problem rather than a defect in the code under test.
    static func start(
        store: BuzzEventStore,
        signer: InMemorySigner,
        peer: String
    ) async throws -> LiveDirectMessageProbe? {
        let live = LiveEngine(store: store, signer: signer)
        try await live.engine.start()
        guard await poll(timeout: .seconds(30), { await live.engine.state == .running }) else {
            Issue.record("[LIVE] engine never reached running")
            await live.engine.stop()
            return nil
        }
        return LiveDirectMessageProbe(
            engine: live.engine,
            connection: live.connection,
            directory: ChannelDirectoryClient(
                transport: URLSessionHTTPTransport(),
                queryURL: LiveRelay.queryURL,
                signer: signer
            ),
            signer: signer,
            identity: try await signer.publicKey().hex,
            channel: try await live.engine.openDirectMessage(with: peer)
        )
    }

    /// The DM's state in a fresh authoritative pass. `previouslyActiveChannels` carries
    /// it so a demotion can never be confused with the channel simply falling out of the
    /// answer.
    func state() async -> ChannelAccessState? {
        try? await directory
            .fetch(selfPubkey: identity, previouslyActiveChannels: [channel])
            .states[channel]
    }

    /// Kind 41012, `h` = the DM, empty content — the same event Desktop's hide button
    /// publishes. Reports whether the relay accepted it.
    func hide() async -> Bool {
        guard let event = try? await signer.sign(
            kind: .directMessageHide,
            content: "",
            tags: [["h", channel]]
        ) else {
            Issue.record("[LIVE] could not sign the DM hide")
            return false
        }
        if let rejection = await tryPublish(event, on: connection) {
            Issue.record("[LIVE] relay refused the DM hide: \(rejection)")
            return false
        }
        return true
    }

    /// Polls until the DM reaches `expected`. The snapshot is republished post-commit
    /// and best-effort, so it is not readable the instant the command is acknowledged.
    func waitFor(_ expected: ChannelAccessState) async -> Bool {
        await poll(timeout: .seconds(20)) { await state() == expected }
    }

    func rosterStillNamesMe() async -> Bool {
        guard let snapshot = try? await directory.fetch(
            selfPubkey: identity,
            previouslyActiveChannels: [channel]
        ) else { return false }
        return snapshot.events.contains { event in
            event.kind == EventKind.groupMembers
                && event.addressableIdentifier == channel
                && event.tags.contains { $0.count > 1 && $0[0] == "p" && $0[1] == identity }
        }
    }

    func stop() async {
        await engine.stop()
    }
}
