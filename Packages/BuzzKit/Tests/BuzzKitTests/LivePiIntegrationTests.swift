@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

/// The live instrumented run against the Buzz Pi relay (spec §"Live instrumented
/// run"). Disabled unless `BUZZKIT_INTEGRATION_URL` names the relay, so `make test`
/// and CI never touch the network — the same gate the Phase-1 `RelayIntegrationTests`
/// use. The deterministic T1–T8 suites are the CI gate; this proves the same no-loss
/// guarantees against a real relay and captures three relay-behavior findings.
///
/// Run:
/// `BUZZKIT_INTEGRATION_URL=wss://homelab.tail4bc643.ts.net swift test -c release \
///   --package-path Packages/BuzzKit --filter LivePi`
@Suite("Live Pi integration", .enabled(if: LiveRelay.enabled), .serialized, .timeLimit(.minutes(5)))
struct LivePiIntegrationTests {
    /// The scenario: a second connection publishes messages while the engine
    /// connection cycles background/foreground and stop/relaunch; the store must
    /// converge on every message with no duplicates, and a message composed while the
    /// engine was stopped must drain on relaunch.
    @Test("Store converges across lifecycle cycling and drains a message composed while stopped")
    func convergesAcrossLifecycleCycling() async throws {
        let signer = try InMemorySigner() // throwaway; creator ⇒ member, so no join flow
        let channel = LiveRelay.channelID()
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        // The "second connection" — provisions the channel and publishes every peer
        // message; a separate socket from the engine's own.
        guard let peer = await provision(channel: channel, signer: signer, store: store) else { return }

        // Engine instance 1.
        let engine1 = LiveEngine(store: store, signer: signer)
        try await engine1.engine.start()
        guard await poll(timeout: .seconds(30), { await engine1.engine.state == .running }) else {
            Issue.record("[LIVE] engine never reached running")
            await engine1.engine.stop(); await peer.stop()
            return
        }
        print("[LIVE] engine running")

        // Finding (1) on the empty channel: a served bounds overlay proves the fast path
        // even before any rows exist.
        await captureWindowFinding(channel: channel, signer: signer, label: "empty")

        // The churn: publish across a background/foreground cycle and a stop/relaunch,
        // composing one message while the engine is fully down.
        let (expected, composed) = try await driveLifecycle(
            engine1: engine1, store: store, channel: channel, peer: peer, signer: signer
        )

        // Relaunch on the same store — a real app restart.
        let engine2 = LiveEngine(store: store, signer: signer)
        try await engine2.engine.start()
        guard await poll(timeout: .seconds(30), { await engine2.engine.state == .running }) else {
            Issue.record("[LIVE] relaunched engine never reached running")
            await engine2.engine.stop(); await peer.stop()
            return
        }
        print("[LIVE] engine relaunched and running")

        try await assertConvergence(store: store, channel: channel, expected: expected, composed: composed)

        // Findings captured after convergence.
        await captureWindowFinding(channel: channel, signer: signer, label: "populated")
        await captureMembershipFinding(signer: signer, on: peer)
        print("[LIVE] finding(3) NIP-OA agent auth tags: SKIPPED — a self-provisioned "
            + "throwaway channel has no agent-authored messages to inspect")

        await engine2.engine.stop()
        await peer.stop()
    }

    // MARK: - Scenario phases

    /// Connects the peer, self-provisions the channel (kind 9007), and seeds it into
    /// `channel_sync` so reconcile runs independent of discovery. Returns the peer
    /// connection, or `nil` (recording the reason) if the relay was unreachable or
    /// rejected the provision.
    private func provision(channel: String, signer: some EventSigner, store: BuzzEventStore) async -> RelayConnection? {
        let peer = RelayConnection(url: LiveRelay.wsURL, signer: signer)
        guard await connectAndWaitReady(peer) else {
            Issue.record("[LIVE] peer connection never reached ready — relay unreachable or auth failed")
            return nil
        }
        print("[LIVE] peer connected and authenticated to \(LiveRelay.wsURL)")

        do {
            let create = try await createChannelEvent(
                channel: channel, name: "buzzkit-p2-\(channel.prefix(8))", signer: signer
            )
            if let rejection = await tryPublish(create, on: peer) {
                Issue.record("[LIVE] channel self-provision (kind 9007) rejected: \(rejection)")
                await peer.stop()
                return nil
            }
            print("[LIVE] provisioned channel \(channel)")

            try await store.executeForTest("""
            INSERT OR IGNORE INTO channel_sync (channel_id, watermark_created_at, watermark_id, head_synced)
            VALUES ('\(channel)', NULL, NULL, 0)
            """)
            return peer
        } catch {
            Issue.record("[LIVE] provision threw: \(error)")
            await peer.stop()
            return nil
        }
    }

    /// Publishes six peer messages across a background/foreground cycle and a full stop,
    /// composing one message while the engine is stopped. Returns the ids expected in the
    /// store and the composed entry. The engine is left stopped for the caller to relaunch.
    private func driveLifecycle(
        engine1: LiveEngine, store: BuzzEventStore, channel: String,
        peer: RelayConnection, signer: some EventSigner
    ) async throws -> (expected: [String], composed: OutboxEntry) {
        var expected: [String] = []
        expected += await publishBatch(["e1", "e2"], channel: channel, on: peer, signer: signer)

        await engine1.engine.enterBackground()
        _ = await poll(timeout: .seconds(15)) { await engine1.engine.state == .suspended }
        print("[LIVE] engine suspended: \(await engine1.engine.state)")
        expected += await publishBatch(["e3", "e4"], channel: channel, on: peer, signer: signer)
        await engine1.engine.enterForeground()
        _ = await poll(timeout: .seconds(30)) { await engine1.engine.state == .running }
        print("[LIVE] engine foregrounded: \(await engine1.engine.state)")

        await engine1.engine.stop()
        print("[LIVE] engine stopped")
        let composed = try await store.enqueue(
            content: "composed-while-stopped", in: channel, tags: [["h", channel]], with: signer
        )
        expected.append(composed.event.id)
        expected += await publishBatch(["e5", "e6"], channel: channel, on: peer, signer: signer)
        return (expected, composed)
    }

    /// Asserts the store converged on every expected message with no duplicates and the
    /// outbox drained. Bounded so a non-converging relay reports rather than hangs.
    private func assertConvergence(
        store: BuzzEventStore, channel: String, expected: [String], composed: OutboxEntry
    ) async throws {
        let expectedIDs = expected
        let converged = await poll(timeout: .seconds(45)) {
            let ids = (try? await self.channelMessageIDs(store, channel: channel)) ?? []
            let outbox = (try? await store.outboxCount()) ?? 1
            return Set(ids).isSuperset(of: expectedIDs) && outbox == 0
        }

        let storedIDs = try await channelMessageIDs(store, channel: channel)
        let present = Set(storedIDs)
        let missing = expected.filter { !present.contains($0) }
        let outboxCount = try await store.outboxCount()
        print("[LIVE] convergence: \(present.count) stored, \(expected.count) expected, "
            + "\(missing.count) missing, outbox \(outboxCount)")
        if !missing.isEmpty { print("[LIVE] missing ids: \(missing)") }

        // No duplicates is structural (id is the primary key); this asserts every
        // expected message actually landed and the composed one drained.
        #expect(converged, "store did not converge on all published + composed messages")
        #expect(present.isSuperset(of: expected))
        #expect(storedIDs.count == present.count) // distinct ⇒ no dups
        #expect(try await store.event(id: composed.event.id) != nil) // outbox drain landed it
        #expect(outboxCount == 0)
    }

    // MARK: - Findings

    /// Finding (1): probes `POST /query` for the channel and reports whether the relay
    /// serves a valid NIP-CW window (a `kind:39006` bounds overlay) or degrades to WS
    /// assembly. Writes the raw response to a temp file for fixture capture; `label`
    /// distinguishes the empty-channel probe from the populated one.
    private func captureWindowFinding(channel: String, signer: some EventSigner, label: String) async {
        let client = WindowClient(
            transport: URLSessionHTTPTransport(), queryURL: LiveRelay.queryURL, signer: signer
        )
        do {
            switch try await client.fetch(WindowFilter(channelID: channel)) {
            case let .page(page):
                let counts = "rows=\(page.rows.count) aux=\(page.aux.count) "
                    + "summaries=\(page.summaries.count) hasMore=\(page.bounds.hasMore)"
                print("[LIVE] finding(1)/\(label) /query FAST PATH served: \(counts)")
            case let .invalidPage(reason):
                print("[LIVE] finding(1)/\(label) /query served a 39006 but the page was invalid: \(reason)")
            case let .degraded(reason):
                print("[LIVE] finding(1)/\(label) /query DEGRADES to WS assembly (no NIP-CW window): \(reason)")
            }
        } catch {
            print("[LIVE] finding(1)/\(label) /query probe threw: \(error)")
        }

        await captureRawQuery(channel: channel, signer: signer, label: label)
    }

    /// The raw `POST /query` body, written to a temp file for fixture capture, with a
    /// kind histogram — the evidence behind finding (1).
    private func captureRawQuery(channel: String, signer: some EventSigner, label: String) async {
        do {
            let body = try WindowFilter(channelID: channel).encodedRequestBody()
            let header = try await NIP98.authorizationHeader(
                url: LiveRelay.queryURL, method: "POST", body: body, signer: signer
            )
            let (data, status) = try await URLSessionHTTPTransport().post(
                body: body, to: LiveRelay.queryURL,
                headers: ["Content-Type": "application/json", "Authorization": header]
            )
            let events = (try? JSONDecoder().decode([NostrEvent].self, from: data)) ?? []
            let kinds = Dictionary(grouping: events, by: { $0.kind.rawValue }).mapValues(\.count)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("buzzkit-live-query-\(label)-\(channel.prefix(8)).json")
            try? data.write(to: path)
            print("[LIVE] finding(1)/\(label) raw /query: status=\(status) "
                + "bytes=\(data.count) kinds=\(kinds) captured=\(path.path)")
        } catch {
            print("[LIVE] finding(1)/\(label) raw /query capture threw: \(error)")
        }
    }

    /// Finding (2): queries the relay-signed membership notifications for self and reports
    /// whether they carry the channel in an `h` tag.
    private func captureMembershipFinding(signer: some EventSigner, on connection: RelayConnection) async {
        do {
            let selfHex = try await signer.publicKey().hex
            let events = try await connection.query(
                [Filter(kinds: [.memberAdded, .memberRemoved], tagQueries: ["p": [selfHex]])],
                timeout: .seconds(15)
            )
            guard !events.isEmpty else {
                print("[LIVE] finding(2) membership 44100/44101: none returned for self")
                return
            }
            for event in events {
                let hTags = event.tags.filter { $0.first == "h" }.map { $0.count > 1 ? $0[1] : "" }
                print("[LIVE] finding(2) membership kind=\(event.kind.rawValue) h-tags=\(hTags) tags=\(event.tags)")
            }
        } catch {
            print("[LIVE] finding(2) membership query threw: \(error)")
        }
    }

    // MARK: - Helpers

    /// Publishes each content as a #h-scoped kind-9 on `connection`, returning the ids
    /// that were accepted (a rejection is recorded and its id omitted from `expected`).
    private func publishBatch(
        _ contents: [String], channel: String, on connection: RelayConnection, signer: some EventSigner
    ) async -> [String] {
        var accepted: [String] = []
        for content in contents {
            let event = try? await channelMessageEvent(content, channel: channel, signer: signer)
            guard let event else { continue }
            if let rejection = await tryPublish(event, on: connection) {
                print("[LIVE] publish \(content) rejected: \(rejection)")
            } else {
                accepted.append(event.id)
            }
        }
        return accepted
    }

    /// The ids of every kind-9 event stored for `channel`, distinct by construction (the
    /// event id is the primary key).
    private func channelMessageIDs(_ store: BuzzEventStore, channel: String) async throws -> [String] {
        try await store.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT id FROM event WHERE h = ? AND kind = ?",
                arguments: [channel, EventKind.channelMessage.rawValue]
            )
        }
    }
}
