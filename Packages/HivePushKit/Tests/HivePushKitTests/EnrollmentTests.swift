import Foundation
@testable import HivePushKit
import NostrCore
import Testing

// MARK: - EnrollmentStore tests

@Suite("Enrollment store", .timeLimit(.minutes(1)))
struct EnrollmentStoreTests {
    private func makeStore() -> (EnrollmentStore, URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnrollmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (EnrollmentStore(containerURL: container), container)
    }

    private func enrollment(
        communityID: String = UUID().uuidString,
        installationHandle: String = "handle-1",
        endpointGrant: String = "grant-1"
    ) -> Enrollment {
        Enrollment(
            communityID: communityID,
            installationHandle: installationHandle,
            endpointGrant: endpointGrant,
            attestKeyID: "key-1",
            installID: UUID().uuidString,
            relayURL: "wss://relay.example",
            enrolledAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    @Test("Write then read round-trips")
    func writeThenRead() throws {
        let (store, _) = makeStore()
        let record = enrollment()
        try store.write(record)
        let loaded = store.load(communityID: record.communityID)
        #expect(loaded == record)
    }

    @Test("Absent community reads as nil")
    func absentReadsNil() {
        let (store, _) = makeStore()
        #expect(store.load(communityID: "nonexistent") == nil)
    }

    @Test("Remove clears one enrollment")
    func removeOne() throws {
        let (store, _) = makeStore()
        let e1 = enrollment(communityID: "a")
        let e2 = enrollment(communityID: "b")
        try store.write(e1)
        try store.write(e2)
        store.remove(communityID: "a")
        #expect(store.load(communityID: "a") == nil)
        #expect(store.load(communityID: "b") != nil)
    }

    @Test("RemoveAll clears everything")
    func removeAll() throws {
        let (store, _) = makeStore()
        try store.write(enrollment(communityID: "a"))
        try store.write(enrollment(communityID: "b"))
        store.removeAll()
        #expect(store.loadAll().isEmpty)
    }

    @Test("LoadAll returns all enrollments")
    func loadAll() throws {
        let (store, _) = makeStore()
        try store.write(enrollment(communityID: "a"))
        try store.write(enrollment(communityID: "b"))
        let all = store.loadAll()
        #expect(all.count == 2)
    }

    @Test("Pending revocation round-trips with handle and key")
    func pendingRevocationRoundTrip() {
        let (store, _) = makeStore()
        #expect(store.loadPendingRevocation(communityID: "c1") == nil)
        let record = PendingRevocation(communityID: "c1", installationHandle: "h-99", attestKeyID: "k-99")
        store.savePendingRevocation(record)
        #expect(store.loadPendingRevocation(communityID: "c1") == record)
        store.removePendingRevocation(communityID: "c1")
        #expect(store.loadPendingRevocation(communityID: "c1") == nil)
    }

    @Test("Demote moves an enrollment's credentials into the pending set")
    func demoteToPendingRevocation() throws {
        let (store, _) = makeStore()
        let e = enrollment(communityID: "c1", installationHandle: "h-1")
        try store.write(e)
        store.demoteToPendingRevocation(communityID: "c1")
        #expect(store.load(communityID: "c1") == nil)
        #expect(store.loadPendingRevocation(communityID: "c1") == PendingRevocation(enrollment: e))

        // No enrollment: nothing is written.
        store.demoteToPendingRevocation(communityID: "c2")
        #expect(store.loadPendingRevocation(communityID: "c2") == nil)
    }

    @Test("LoadAllPendingRevocations spans communities")
    func loadAllPending() {
        let (store, _) = makeStore()
        #expect(store.loadAllPendingRevocations().isEmpty)
        store.savePendingRevocation(PendingRevocation(communityID: "a", installationHandle: "h-a", attestKeyID: "k-a"))
        store.savePendingRevocation(PendingRevocation(communityID: "b", installationHandle: "h-b", attestKeyID: "k-b"))
        let handles = Set(store.loadAllPendingRevocations().map(\.installationHandle))
        #expect(handles == ["h-a", "h-b"])
    }
}

// MARK: - EnrollmentDriver tests

@Suite("Enrollment driver", .timeLimit(.minutes(1)))
struct EnrollmentDriverTests {
    private func makeStore() -> EnrollmentStore {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnrollmentDriverTests-\(UUID().uuidString)", isDirectory: true)
        return EnrollmentStore(containerURL: container)
    }

    @Test("Enrollment stops at attest when App Attest is unsupported")
    func attestUnsupported() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let publishedEvents: ActorBox<[NostrEvent]> = ActorBox([])

        // Gateway that returns a valid challenge.
        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
        ])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: false),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { event in
                await publishedEvents.append(event)
            }
        )

        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                // Simulate immediate token delivery.
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )

        let state = await driver.state
        guard case let .failed(step, message) = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
        #expect(step == .attest)
        #expect(message.contains("not supported"))
    }

    @Test("Enrollment fails at permission denied")
    func permissionDenied() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let transport = ScriptedTransport(responses: [])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: false),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

        await driver.enroll(
            requestPermission: { false },
            registerForRemoteNotifications: {}
        )

        let state = await driver.state
        guard case let .failed(step, _) = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
        #expect(step == .permission)
    }

    @Test("Full enrollment succeeds with fake attest provider")
    func fullEnrollmentSuccess() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let publishedEvents: ActorBox<[NostrEvent]> = ActorBox([])

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let installJSON = #"{"installation_handle":"handle-1","endpoint_epoch":1,"expires_at":1700086400}"#
        let challenge2JSON = #"{"challenge_id":"ch-2","challenge":"nonce2","expires_at":1700000600}"#
        let delegationJSON = #"{"endpoint_grant":"grant-1"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),   // enroll challenge
            (Data(installJSON.utf8), 201),      // install
            (Data(challenge2JSON.utf8), 200),   // delegate challenge
            (Data(delegationJSON.utf8), 201),   // delegate
        ])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { event in
                await publishedEvents.append(event)
            }
        )

        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )

        let state = await driver.state
        #expect(state == .enrolled)

        // Verify the enrollment was persisted.
        let enrollment = store.load(communityID: "comm-1")
        #expect(enrollment != nil)
        #expect(enrollment?.installationHandle == "handle-1")
        #expect(enrollment?.endpointGrant == "grant-1")

        // Verify a lease event was published.
        let events = await publishedEvents.value
        #expect(events.count == 1)
        let leaseEvent = events[0]
        #expect(leaseEvent.kind == .pushLease)
        // The lease should have a d tag, expiration, exec, and relay tags.
        #expect(leaseEvent.tags.contains { $0.first == "d" })
        #expect(leaseEvent.tags.contains { $0.first == "expiration" })
        #expect(leaseEvent.tags.contains { $0.first == "exec" })
        #expect(leaseEvent.tags.contains { $0.first == "relay" })
    }

    @Test("Revoke keeps handle and key as pending revocation when the gateway is unreachable")
    func revokeEnrollment() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let publishedEvents: ActorBox<[NostrEvent]> = ActorBox([])

        // Pre-seed an enrollment.
        try store.write(Enrollment(
            communityID: "comm-1",
            installationHandle: "handle-1",
            endpointGrant: "grant-1",
            attestKeyID: "key-1",
            installID: "install-1",
            relayURL: "wss://relay.example"
        ))

        // No scripted responses — the revoke challenge fails.
        let transport = ScriptedTransport(responses: [])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { event in
                await publishedEvents.append(event)
            }
        )

        await driver.revoke()

        #expect(store.load(communityID: "comm-1") == nil)
        let state = await driver.state
        #expect(state == .idle)

        // Both the handle and the key survive, so a later 409 can revoke it.
        #expect(store.loadPendingRevocation(communityID: "comm-1")
            == PendingRevocation(communityID: "comm-1", installationHandle: "handle-1", attestKeyID: "key-1"))

        // A deletion event should have been published.
        let events = await publishedEvents.value
        #expect(events.count == 1)
        #expect(events[0].kind == .deletion)
    }

    @Test("Revoke sends a challenge-bound assertion signed by the enrollment's key")
    func revokeCallsGateway() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let attest = FakeAttestProvider(supported: true)

        try store.write(Enrollment(
            communityID: "comm-1",
            installationHandle: "handle-1",
            endpointGrant: "grant-1",
            attestKeyID: "key-1",
            installID: "install-1",
            relayURL: "wss://relay.example"
        ))

        let challengeJSON = #"{"challenge_id":"ch-r","challenge":"nonce-r","expires_at":1700000300}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),     // revoke challenge
            (Data(#"{"status":"revoked"}"#.utf8), 200), // gateway revoke
        ])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: attest,
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

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
        #expect(store.loadPendingRevocation(communityID: "comm-1") == nil)
        let state = await driver.state
        #expect(state == .idle)
    }

    @Test("409 is recovered by revoking a pending installation with its own key, then re-enrolling from a fresh challenge")
    func installConflictRecoveryFromPendingRevocation() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let attest = FakeAttestProvider(supported: true)

        // A prior revoke failed (offline), so the old installation's credentials
        // were kept — under another community, since installations are per device.
        store.savePendingRevocation(PendingRevocation(
            communityID: "comm-old", installationHandle: "old-handle", attestKeyID: "old-key"
        ))

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
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: attest,
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )

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
        #expect(store.loadPendingRevocation(communityID: "comm-old") == nil)
        #expect(store.load(communityID: "comm-1")?.installationHandle == "new-handle")
    }

    @Test("409 with no pending credentials fails with the operator message and makes no revoke call")
    func installConflictWithoutCredentials() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(conflictJSON.utf8), 409),
        ])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )

        let state = await driver.state
        #expect(state == .failed(.install, EnrollmentDriver.unrecoverableConflictMessage))
        #expect(transport.requests.count == 2)
        #expect(store.load(communityID: "comm-1") == nil)
    }

    @Test("409 persisting after the pending installation is already gone fails rather than looping")
    func installConflictPersistsAfterRevoke() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        store.savePendingRevocation(PendingRevocation(
            communityID: "comm-1", installationHandle: "stale-handle", attestKeyID: "stale-key"
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
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )

        let state = await driver.state
        #expect(state == .failed(.install, EnrollmentDriver.unrecoverableConflictMessage))
        #expect(transport.requests.count == 6)
        // The stale record is dropped so it is not retried forever.
        #expect(store.loadPendingRevocation(communityID: "comm-1") == nil)
    }

    @Test("409 recovery reports a revoke transport failure instead of retrying")
    func installConflictRevokeFails() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        store.savePendingRevocation(PendingRevocation(
            communityID: "comm-1", installationHandle: "old-handle", attestKeyID: "old-key"
        ))

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(conflictJSON.utf8), 409),
            (Data(challengeJSON.utf8), 200),
            (Data(#"{"error":"temporarily_unavailable"}"#.utf8), 503),
        ])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

        await driver.enroll(
            requestPermission: { true },
            registerForRemoteNotifications: {
                Task { await driver.didReceiveDeviceToken("abcd1234") }
            }
        )

        let state = await driver.state
        guard case let .failed(step, message) = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
        #expect(step == .install)
        #expect(message.hasPrefix("Failed to revoke existing installation"))
        #expect(transport.requests.count == 4)
        // Credentials are kept for the next attempt.
        #expect(store.loadPendingRevocation(communityID: "comm-1")?.installationHandle == "old-handle")
    }

    @Test("Second enroll() while in flight is a no-op")
    func reentrancyGuard() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()

        // A challenge response that hangs until we unblock it.
        let gate = ActorBox(false)
        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let installJSON = #"{"installation_handle":"handle-1","endpoint_epoch":1,"expires_at":1700086400}"#
        let challenge2JSON = #"{"challenge_id":"ch-2","challenge":"nonce2","expires_at":1700000600}"#
        let delegationJSON = #"{"endpoint_grant":"grant-1"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),   // enroll challenge
            (Data(installJSON.utf8), 201),      // install
            (Data(challenge2JSON.utf8), 200),   // delegate challenge
            (Data(delegationJSON.utf8), 201),   // delegate
        ])
        let gateway = GatewayClient(
            baseURL: URL(string: "http://gateway.test:3005")!,
            transport: transport
        )

        let driver = EnrollmentDriver(
            gateway: gateway,
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: signer,
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd",
            publishEvent: { _ in }
        )

        // Start the first enroll; it will suspend waiting for a device token.
        let first = Task {
            await driver.enroll(
                requestPermission: { true },
                registerForRemoteNotifications: {
                    // Do NOT deliver a token yet — keep enroll() suspended.
                }
            )
        }

        // Yield to let the first enroll reach awaitingDeviceToken.
        try await Task.sleep(for: .milliseconds(50))
        let midState = await driver.state
        #expect(midState == .awaitingDeviceToken)

        // Second call should return immediately, leaving state unchanged.
        await driver.enroll(
            requestPermission: { Issue.record("Permission should not be re-requested"); return false },
            registerForRemoteNotifications: { Issue.record("Should not re-register") }
        )

        let afterState = await driver.state
        #expect(afterState == .awaitingDeviceToken)

        // Clean up: deliver a token so the first enroll can finish.
        await driver.didReceiveDeviceToken("abcd1234")
        await first.value
    }
}

// MARK: - PushCapability tests

@Suite("Push capability parsing", .timeLimit(.minutes(1)))
struct PushCapabilityTests {
    @Test("Parses a well-formed NIP-11 push object")
    func parseSuccess() throws {
        let json = """
        {
            "push": {
                "keys": [{"id": "relay-v1", "pubkey": "aabb", "current": true}],
                "app_profiles": [{"id": "buzz-ios-dogfood", "transport": "apns"}],
                "push_kinds": [9, 40002],
                "origin": "wss://relay.example"
            }
        }
        """
        let cap = PushCapability.parse(fromRelayInfoData: Data(json.utf8))
        #expect(cap != nil)
        #expect(cap?.supportsHive == true)
        #expect(cap?.currentKey?.pubkey == "aabb")
        #expect(cap?.pushKinds == [9, 40002])
    }

    @Test("Returns nil when no push object exists")
    func noPush() {
        let json = #"{"name":"Relay","software":"other"}"#
        #expect(PushCapability.parse(fromRelayInfoData: Data(json.utf8)) == nil)
    }

    @Test("Reports unsupported when app profile is missing")
    func wrongProfile() {
        let json = """
        {"push":{"keys":[],"app_profiles":[{"id":"other-app","transport":"apns"}],"push_kinds":[]}}
        """
        let cap = PushCapability.parse(fromRelayInfoData: Data(json.utf8))
        #expect(cap?.supportsHive == false)
    }
}

// MARK: - Test doubles

/// A fake App Attest provider for testing. Records which keys it was asked to
/// generate and assert with, so tests can tell a stored key from a fresh one.
struct FakeAttestProvider: AppAttestProviding {
    let supported: Bool
    let generatedKeyCount = ActorBox(0)
    let assertedKeyIDs = ActorBox<[String]>([])

    init(supported: Bool) {
        self.supported = supported
    }

    var isSupported: Bool { supported }

    func generateKey() async throws -> String {
        guard supported else { throw FakeAttestError.unsupported }
        let n = await generatedKeyCount.increment()
        return "fake-key-id-\(n)"
    }

    func attest(keyID _: String, clientDataHash _: Data) async throws -> Data {
        guard supported else { throw FakeAttestError.unsupported }
        return Data("fake-attestation".utf8)
    }

    func assert(keyID: String, clientDataHash _: Data) async throws -> Data {
        guard supported else { throw FakeAttestError.unsupported }
        await assertedKeyIDs.append(keyID)
        return Data("fake-assertion".utf8)
    }
}

enum FakeAttestError: Error {
    case unsupported
}

/// A simple actor-isolated box for collecting values across async boundaries.
actor ActorBox<T> {
    var value: T

    init(_ initial: T) {
        value = initial
    }
}

extension ActorBox where T: RangeReplaceableCollection {
    func append(_ element: T.Element) {
        value.append(element)
    }
}

extension ActorBox where T == Int {
    /// Increments and returns the new value.
    func increment() -> Int {
        value += 1
        return value
    }
}
