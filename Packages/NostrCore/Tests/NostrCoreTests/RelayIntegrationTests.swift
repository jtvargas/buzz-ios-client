import Foundation
@testable import NostrCore
import Testing

/// Live end-to-end checks against a real Buzz relay — the Phase 1 exit
/// criteria. Disabled unless `NOSTRCORE_INTEGRATION_URL` names a relay
/// (e.g. `wss://relay.example.com`), so CI and ordinary local runs never
/// touch the network. The HTTP bridge base is derived from the same host.
///
/// Run: `NOSTRCORE_INTEGRATION_URL=wss://… swift test -c release \
///   --package-path Packages/NostrCore --filter RelayIntegration`
private let integrationRelay = ProcessInfo.processInfo.environment["NOSTRCORE_INTEGRATION_URL"]

@Suite("Live relay integration", .enabled(if: integrationRelay != nil), .serialized)
struct RelayIntegrationTests {
    private var relayURL: URL {
        URL(string: integrationRelay!)!
    }

    private var httpBase: URL {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "ws" ? "http" : "https"
        return components.url!
    }

    /// Collects sink deliveries for the live-subscription leg.
    private actor CollectingSink: EventSink {
        private(set) var batches: [(phase: IngestPhase, count: Int)] = []
        private(set) var eoseSeen = false
        private var eoseWaiters: [CheckedContinuation<Void, Never>] = []

        func ingest(batch: [NostrEvent], subscription _: SubscriptionID, phase: IngestPhase) {
            batches.append((phase, batch.count))
        }

        func endOfStoredEvents(subscription _: SubscriptionID) {
            eoseSeen = true
            let waiters = eoseWaiters
            eoseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func subscriptionClosed(subscription _: SubscriptionID, error _: SubscriptionError) {}

        func awaitEOSE() async {
            if eoseSeen { return }
            await withCheckedContinuation { eoseWaiters.append($0) }
        }
    }

    @Test("NIP-11 advertises the limits the spec relies on", .timeLimit(.minutes(1)))
    func nip11Limits() async throws {
        var request = URLRequest(url: httpBase)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let limitation = document?["limitation"] as? [String: Any]
        #expect(limitation != nil, "relay must serve a NIP-11 limitation document")
        // The relay-source facts the sync design depends on (spec §Newly verified).
        #expect(limitation?["max_filters"] as? Int == 10)
        #expect(limitation?["max_limit"] as? Int == 10000)
        #expect(limitation?["max_subscriptions"] as? Int == 1024)
    }

    @Test("Connect, authenticate, subscribe, publish, and query round-trip", .timeLimit(.minutes(2)))
    func fullProtocolRoundTrip() async throws {
        let signer = try InMemorySigner()
        let connection = RelayConnection(url: relayURL, signer: signer)

        // Connect → NIP-42 AUTH → ready.
        try await connection.connect()
        let states = await connection.connectionStates()
        for await state in states {
            if state == .ready { break }
            if case .stopped = state {
                Issue.record("connection stopped before reaching ready: \(state)")
                return
            }
        }

        // Live kind-9 subscription reaches EOSE (backfill complete).
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = CollectingSink()
        _ = try await manager.register(filters: [Filter(kinds: [.channelMessage], limit: 5)], sink: sink)
        await sink.awaitEOSE()

        // Publish → relay OK. A plain text note from a throwaway key; content
        // marks it as an automated probe.
        let note = try await signer.sign(
            kind: .textNote,
            content: "NostrCore integration probe \(UUID().uuidString)"
        )
        try await connection.publish(note)

        // One-shot query returns the event we just stored.
        let publicKey = try await signer.publicKey()
        let echoed = try await connection.query([Filter(ids: [note.id], authors: [publicKey.hex])])
        #expect(echoed.contains { $0.id == note.id })
        let echoedAllValid = echoed.allSatisfy(\.isValid)
        #expect(echoedAllValid)

        // NIP-98-signed POST /query over the HTTP bridge round-trips the same
        // event — the pagination path NIP-CW rides in Phase 2.
        let queryURL = httpBase.appendingPathComponent("query")
        let body = try JSONEncoder().encode([Filter(ids: [note.id])])
        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let header = try await NIP98.authorizationHeader(
            url: queryURL,
            method: "POST",
            body: body,
            signer: signer
        )
        request.setValue(header, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 200, "NIP-98 /query must authenticate; got \(status.map(String.init) ?? "nil")")
        let events = try JSONDecoder().decode([NostrEvent].self, from: data)
        #expect(events.contains { $0.id == note.id })

        await connection.stop()
    }

    @Test("A kindless WS query documents the relay's actual behavior", .timeLimit(.minutes(1)))
    func kindlessFilterProbe() async throws {
        let signer = try InMemorySigner()
        let connection = RelayConnection(url: relayURL, signer: signer)
        try await connection.connect()
        let states = await connection.connectionStates()
        for await state in states where state == .ready {
            break
        }

        let publicKey = try await signer.publicKey()
        // The reference client reports the relay rejects kindless filters; relay
        // source shows WS treats an *absent* kinds list as a wildcard. Probe and
        // accept either a result set or a typed close — never a hang or crash.
        do {
            let events = try await connection.query(
                [Filter(authors: [publicKey.hex], limit: 1)],
                timeout: .seconds(10)
            )
            let probeAllValid = events.allSatisfy(\.isValid)
            #expect(events.isEmpty || probeAllValid)
        } catch let error as RelayConnectionError {
            // A typed rejection is an acceptable outcome; record which for the docs.
            print("kindless probe: relay rejected with \(error)")
        }
        await connection.stop()
    }
}
