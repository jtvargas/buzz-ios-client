import Foundation
@testable import HivePushKit
import NostrCore
import Testing

// MARK: - EnrollmentDriver revocation and 409 recovery

/// `EnrollmentDriver.revoke()` and the 409 `installation_conflict` path: what
/// the gateway is told, and — above all — what happens to the credentials on
/// every outcome. A handle and key are the only thing that can clear a live
/// installation, so they may only be dropped on a gateway confirmation or
/// once the installation is known to have expired.
@Suite("Enrollment driver revocation", .timeLimit(.minutes(1)))
struct EnrollmentRevocationTests {
    private static let gatewayURL = URL(string: "http://gateway.test:3005")!
    private static let otherGatewayURL = URL(string: "http://other-gateway.test:3005")!
    private static let enrolledAt = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeStoreWithContainer() -> (EnrollmentStore, URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnrollmentRevocationTests-\(UUID().uuidString)", isDirectory: true)
        return (EnrollmentStore(containerURL: container), container)
    }

    private func makeStore() -> EnrollmentStore {
        makeStoreWithContainer().0
    }

    private func enrollment(communityID: String = "comm-1") -> Enrollment {
        Enrollment(
            communityID: communityID,
            installationHandle: "handle-1",
            endpointGrant: "grant-1",
            attestKeyID: "key-1",
            installID: "install-1",
            relayURL: "wss://relay.example",
            gatewayURL: Self.gatewayURL,
            enrolledAt: Self.enrolledAt
        )
    }

    /// A pending record for an installation that is still live as far as this client knows.
    private func pending(
        communityID: String,
        handle: String,
        key: String,
        gatewayURL: URL = EnrollmentRevocationTests.gatewayURL,
        expiresAt: Date = .distantFuture
    ) -> PendingRevocation {
        PendingRevocation(
            communityID: communityID,
            gatewayURL: gatewayURL,
            installationHandle: handle,
            attestKeyID: key,
            installationExpiresAt: expiresAt
        )
    }

    /// A driver over `store` and `transport`, bound to the test gateway and community `comm-1`.
    private func makeDriver(
        store: EnrollmentStore,
        transport: ScriptedTransport,
        attest: FakeAttestProvider = FakeAttestProvider(supported: true),
        publishEvent: @escaping @Sendable (NostrEvent) async throws -> Void = { _ in }
    ) throws -> EnrollmentDriver {
        EnrollmentDriver(
            gateway: GatewayClient(baseURL: Self.gatewayURL, transport: transport),
            attestProvider: attest,
            enrollmentStore: store,
            signer: try InMemorySigner(),
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: publishEvent
        )
    }

    /// Runs `enroll()` with permission granted and a device token delivered at once.
    private func enrollWithToken(_ driver: EnrollmentDriver) async {
        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )
    }

    @Test("Revoke persists the pending record before the network call and keeps it when the gateway is unreachable")
    func revokeEnrollment() async throws {
        let store = makeStore()
        let publishedEvents: ActorBox<[NostrEvent]> = ActorBox([])

        // Pre-seed an enrollment.
        let seeded = enrollment()
        try store.write(seeded)

        // No scripted responses — the revoke challenge fails. By the time that
        // request leaves, the credentials must already be on disk as pending:
        // a crash during the await is then recoverable by the 409 path.
        let transport = ScriptedTransport(responses: [])
        let atChallenge = StoreSnapshot()
        transport.onRequest = { _ in
            atChallenge.pending = store.pendingRecords(for: "comm-1")
            atChallenge.enrollment = store.load(communityID: "comm-1")
        }

        let driver = try makeDriver(store: store, transport: transport) { event in
            await publishedEvents.append(event)
        }

        await driver.revoke()

        #expect(transport.requests.count == 1)
        #expect(store.load(communityID: "comm-1") == nil)
        let state = await driver.state
        #expect(state == .idle)

        // Gateway, handle, key and expiry survive, so a later 409 on this gateway can revoke it.
        let expected = PendingRevocation(enrollment: seeded, gatewayURL: Self.gatewayURL)
        #expect(store.pendingRecords(for: "comm-1") == [expected])
        #expect(atChallenge.pending == [expected])
        #expect(atChallenge.enrollment == nil)

        // A deletion event should have been published.
        let events = await publishedEvents.value
        #expect(events.count == 1)
        #expect(events[0].kind == .deletion)
    }

    @Test("Revoke sends a challenge-bound assertion signed by the enrollment's key")
    func revokeCallsGateway() async throws {
        let store = makeStore()
        let attest = FakeAttestProvider(supported: true)

        try store.write(enrollment())

        let challengeJSON = #"{"challenge_id":"ch-r","challenge":"nonce-r","expires_at":1700000300}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),     // revoke challenge
            (Data(#"{"status":"revoked"}"#.utf8), 200), // gateway revoke
        ])

        let driver = try makeDriver(store: store, transport: transport, attest: attest)

        await driver.revoke()

        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].url.path.hasSuffix("/v1/installations/challenges"))
        let revokeRequest = transport.requests[1]
        #expect(revokeRequest.url.path.hasSuffix("/v1/installations/revoke"))
        let body = try JSONSerialization.jsonObject(with: revokeRequest.body) as? [String: Any]
        #expect(body?["v"] as? Int == 1)
        #expect(body?["challenge_id"] as? String == "ch-r")
        #expect(body?["challenge"] as? String == "nonce-r")
        #expect(body?["installation_handle"] as? String == "handle-1")
        #expect(body?["endpoint_epoch"] as? Int == 1)
        #expect(body?["new_endpoint_epoch"] as? Int == 2)
        #expect(body?["assertion"] as? String == Data("fake-assertion".utf8).base64EncodedString())
        // The gateway rejects unknown fields, so the key set must be exact.
        #expect(Set(body?.keys.map { $0 } ?? []) == [
            "v", "challenge_id", "challenge", "installation_handle",
            "endpoint_epoch", "new_endpoint_epoch", "assertion",
        ])

        // The assertion came from the enrolled installation's key, not a fresh one.
        #expect(await attest.assertedKeyIDs.value == ["key-1"])

        #expect(store.load(communityID: "comm-1") == nil)
        #expect(store.pendingRecords(for: "comm-1").isEmpty)
        let state = await driver.state
        #expect(state == .idle)
    }

    @Test("409 is recovered by revoking a pending installation with its own key, then re-enrolling from a fresh challenge")
    func installConflictRecoveryFromPendingRevocation() async throws {
        let store = makeStore()
        let attest = FakeAttestProvider(supported: true)

        // A prior revoke failed (offline), so the old installation's credentials
        // were kept — under another community, since installations are per device.
        try store.savePendingRevocation(pending(communityID: "comm-old", handle: "old-handle", key: "old-key"))

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let revokeChallengeJSON = #"{"challenge_id":"ch-r","challenge":"nonce-r","expires_at":1700000300}"#
        let challenge2JSON = #"{"challenge_id":"ch-2","challenge":"nonce2","expires_at":1700000600}"#
        let installJSON = #"{"installation_handle":"new-handle","endpoint_epoch":1,"expires_at":1700086400}"#
        let challenge3JSON = #"{"challenge_id":"ch-3","challenge":"nonce3","expires_at":1700000900}"#
        let delegationJSON = #"{"endpoint_grant":"grant-1"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),              // enroll challenge
            (Data(conflictJSON.utf8), 409),                // install → 409, challenge consumed
            (Data(revokeChallengeJSON.utf8), 200),         // revoke challenge
            (Data(#"{"status":"revoked"}"#.utf8), 200),   // revoke old installation
            (Data(challenge2JSON.utf8), 200),             // fresh enroll challenge
            (Data(installJSON.utf8), 201),                 // install → success
            (Data(challenge3JSON.utf8), 200),             // delegate challenge
            (Data(delegationJSON.utf8), 201),              // delegate
        ])

        let driver = try makeDriver(store: store, transport: transport, attest: attest)

        await enrollWithToken(driver)

        let state = await driver.state
        #expect(state == .enrolled)

        let paths = transport.requests.map { $0.url.path.components(separatedBy: "/v1/").last ?? "" }
        #expect(paths == [
            "installations/challenges", "installations",
            "installations/challenges", "installations/revoke",
            "installations/challenges", "installations",
            "installations/challenges", "delegations",
        ])

        // The revoke was signed with the pending record's key and bound to its own challenge.
        let revokeBody = try JSONSerialization.jsonObject(with: transport.requests[3].body) as? [String: Any]
        #expect(revokeBody?["installation_handle"] as? String == "old-handle")
        #expect(revokeBody?["challenge_id"] as? String == "ch-r")
        #expect(await attest.assertedKeyIDs.value.first == "old-key")

        // The retried install used the fresh challenge, not the consumed one...
        let retryBody = try JSONSerialization.jsonObject(with: transport.requests[5].body) as? [String: Any]
        #expect(retryBody?["challenge_id"] as? String == "ch-2")
        // ...and a freshly generated key.
        #expect(await attest.generatedKeyCount.value == 2)

        // Pending record settled; enrollment uses the new handle.
        #expect(store.pendingRecords(for: "comm-old").isEmpty)
        #expect(store.load(communityID: "comm-1")?.installationHandle == "new-handle")
    }

    @Test("409 with no pending credentials fails with the operator message and makes no revoke call")
    func installConflictWithoutCredentials() async throws {
        let store = makeStore()

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(conflictJSON.utf8), 409),
        ])

        let driver = try makeDriver(store: store, transport: transport)

        await enrollWithToken(driver)

        let state = await driver.state
        #expect(state == .failed(.install, EnrollmentDriver.unrecoverableConflictMessage))
        #expect(transport.requests.count == 2)
        #expect(store.load(communityID: "comm-1") == nil)
    }

    @Test("409 persisting after the pending installation is already gone fails rather than looping")
    func installConflictPersistsAfterRevoke() async throws {
        let store = makeStore()
        // The installation's known expiry has passed: a 404 now is certain.
        try store.savePendingRevocation(pending(
            communityID: "comm-1", handle: "stale-handle", key: "stale-key",
            expiresAt: Date(timeIntervalSinceNow: -60)
        ))

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let notAuthorizedJSON = #"{"error":"not_authorized"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),        // enroll challenge
            (Data(conflictJSON.utf8), 409),          // install → 409
            (Data(challengeJSON.utf8), 200),        // revoke challenge
            (Data(notAuthorizedJSON.utf8), 404),    // stale record: gateway no longer has it
            (Data(challengeJSON.utf8), 200),        // retry enroll challenge
            (Data(conflictJSON.utf8), 409),          // still blocked by something we can't revoke
        ])

        let driver = try makeDriver(store: store, transport: transport)

        await enrollWithToken(driver)

        let state = await driver.state
        #expect(state == .failed(.install, EnrollmentDriver.unrecoverableConflictMessage))
        #expect(transport.requests.count == 6)
        // The stale record is dropped so it is not retried forever.
        #expect(store.pendingRecords(for: "comm-1").isEmpty)
    }

    @Test("A 404 before the installation's known expiry keeps the credentials and reports the failure")
    func installConflictAmbiguous404KeepsCredentials() async throws {
        let store = makeStore()
        // Still live as far as this client knows: the gateway's 404 could be a
        // consumed challenge or a lost assertion-counter race, not a missing row.
        // Whole seconds: the store persists dates as ISO 8601.
        let record = pending(
            communityID: "comm-1", handle: "live-handle", key: "live-key",
            expiresAt: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded())
        )
        try store.savePendingRevocation(record)

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let notAuthorizedJSON = #"{"error":"not_authorized"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),        // enroll challenge
            (Data(conflictJSON.utf8), 409),          // install → 409
            (Data(challengeJSON.utf8), 200),        // revoke challenge
            (Data(notAuthorizedJSON.utf8), 404),    // ambiguous: challenge consumed / counter race
        ])

        let driver = try makeDriver(store: store, transport: transport)

        await enrollWithToken(driver)

        let state = await driver.state
        guard case let .failed(step, message) = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
        #expect(step == .install)
        #expect(message.hasPrefix("Failed to revoke existing installation"))
        // No retry install: nothing changed on the gateway.
        #expect(transport.requests.count == 4)
        // The credentials are intact for the next attempt, which gets a fresh challenge.
        #expect(store.pendingRecords(for: "comm-1") == [record])
    }

    @Test("409 recovery ignores pending records that belong to another gateway")
    func installConflictIgnoresOtherGatewayRecords() async throws {
        let store = makeStore()
        let foreign = pending(
            communityID: "comm-old", handle: "foreign-handle", key: "foreign-key",
            gatewayURL: Self.otherGatewayURL
        )
        try store.savePendingRevocation(foreign)

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(conflictJSON.utf8), 409),
        ])
        let attest = FakeAttestProvider(supported: true)

        let driver = try makeDriver(store: store, transport: transport, attest: attest)

        await enrollWithToken(driver)

        // The other gateway's handle and key were never sent here, and are untouched.
        let state = await driver.state
        #expect(state == .failed(.install, EnrollmentDriver.unrecoverableConflictMessage))
        #expect(transport.requests.count == 2)
        #expect(await attest.assertedKeyIDs.value.isEmpty)
        #expect(store.pendingRecords(for: "comm-old") == [foreign])
    }

    @Test("Revoke keeps the enrollment when the pending record cannot be written and the gateway is unreachable")
    func revokeKeepsEnrollmentWhenPendingWriteFails() async throws {
        let (store, container) = makeStoreWithContainer()
        let seeded = enrollment()
        try store.write(seeded)
        // A plain file where the pending directory must go makes every pending write fail.
        try Data().write(to: container.appendingPathComponent("PushPendingRevocations"))

        let transport = ScriptedTransport(responses: [])
        let driver = try makeDriver(store: store, transport: transport)

        await driver.revoke()

        // The only copy of the credentials is the enrollment; it stays.
        #expect(store.load(communityID: "comm-1") == seeded)
        #expect(store.loadAllPendingRevocations().isEmpty)
        let state = await driver.state
        #expect(state == .idle)
    }

    @Test("Revoke drops the enrollment without a pending record once the gateway confirms")
    func revokeDropsEnrollmentOnGatewayConfirmationDespitePendingWriteFailure() async throws {
        let (store, container) = makeStoreWithContainer()
        try store.write(enrollment())
        try Data().write(to: container.appendingPathComponent("PushPendingRevocations"))

        let challengeJSON = #"{"challenge_id":"ch-r","challenge":"nonce-r","expires_at":1700000300}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(#"{"status":"revoked"}"#.utf8), 200),
        ])
        let driver = try makeDriver(store: store, transport: transport)

        await driver.revoke()

        #expect(transport.requests.count == 2)
        #expect(store.load(communityID: "comm-1") == nil)
        #expect(store.loadAllPendingRevocations().isEmpty)
    }

    @Test("409 recovery reports a revoke transport failure instead of retrying")
    func installConflictRevokeFails() async throws {
        let store = makeStore()
        try store.savePendingRevocation(pending(communityID: "comm-1", handle: "old-handle", key: "old-key"))

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(conflictJSON.utf8), 409),
            (Data(challengeJSON.utf8), 200),
            (Data(#"{"error":"temporarily_unavailable"}"#.utf8), 503),
        ])

        let driver = try makeDriver(store: store, transport: transport)

        await enrollWithToken(driver)

        let state = await driver.state
        guard case let .failed(step, message) = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
        #expect(step == .install)
        #expect(message.hasPrefix("Failed to revoke existing installation"))
        #expect(transport.requests.count == 4)
        // Credentials are kept for the next attempt.
        #expect(store.pendingRecords(for: "comm-1").map(\.installationHandle) == ["old-handle"])
    }
}

/// What the enrollment store held at one instant, captured synchronously from
/// a transport hook.
final class StoreSnapshot: @unchecked Sendable {
    var pending: [PendingRevocation] = []
    var enrollment: Enrollment?
}

private extension EnrollmentStore {
    func pendingRecords(for communityID: String) -> [PendingRevocation] {
        loadAllPendingRevocations().filter { $0.communityID == communityID }
    }
}
