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

    @Test("Pending handle round-trips")
    func pendingHandleRoundTrip() {
        let (store, _) = makeStore()
        #expect(store.loadPendingHandle(communityID: "c1") == nil)
        store.savePendingHandle("h-99", communityID: "c1")
        #expect(store.loadPendingHandle(communityID: "c1") == "h-99")
        store.removePendingHandle(communityID: "c1")
        #expect(store.loadPendingHandle(communityID: "c1") == nil)
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

    @Test("Revoke removes enrollment, publishes deletion, stashes handle on gateway failure")
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

        // No scripted responses — gateway revoke will fail.
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
            publishEvent: { event in
                await publishedEvents.append(event)
            }
        )

        await driver.revoke()

        #expect(store.load(communityID: "comm-1") == nil)
        let state = await driver.state
        #expect(state == .idle)

        // Gateway revoke failed, so the handle is stashed for 409 recovery.
        #expect(store.loadPendingHandle(communityID: "comm-1") == "handle-1")

        // A deletion event should have been published.
        let events = await publishedEvents.value
        #expect(events.count == 1)
        #expect(events[0].kind == .deletion)
    }

    @Test("Enrollment recovers from 409 by revoking then retrying install")
    func installConflictRecovery() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let publishedEvents: ActorBox<[NostrEvent]> = ActorBox([])

        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"installation_handle":"old-handle"}"#
        let revokeJSON = #"{}"#
        let installJSON = #"{"installation_handle":"new-handle","endpoint_epoch":1,"expires_at":1700086400}"#
        let challenge2JSON = #"{"challenge_id":"ch-2","challenge":"nonce2","expires_at":1700000600}"#
        let delegationJSON = #"{"endpoint_grant":"grant-1"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),   // enroll challenge
            (Data(conflictJSON.utf8), 409),     // install → 409 conflict
            (Data(revokeJSON.utf8), 200),       // revoke old installation
            (Data(installJSON.utf8), 201),      // retry install → success
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

        // Verify the revoke call hit the right endpoint.
        let revokeRequest = transport.requests[2]
        #expect(revokeRequest.url.path.hasSuffix("/v1/installations/revoke"))
        let revokeBody = try JSONSerialization.jsonObject(with: revokeRequest.body) as? [String: Any]
        #expect(revokeBody?["installation_handle"] as? String == "old-handle")

        // Verify final enrollment uses the new handle.
        let enrollment = store.load(communityID: "comm-1")
        #expect(enrollment?.installationHandle == "new-handle")
    }

    @Test("409 without handle in body recovers using stored pending handle")
    func installConflictRecoveryFromPendingHandle() async throws {
        let store = makeStore()
        let signer = try InMemorySigner()
        let publishedEvents: ActorBox<[NostrEvent]> = ActorBox([])

        // Simulate a prior failed revoke that stashed the handle.
        store.savePendingHandle("stashed-handle", communityID: "comm-1")

        // The 409 body does NOT include the handle — just an error string.
        let challengeJSON = #"{"challenge_id":"ch-1","challenge":"nonce","expires_at":1700000300}"#
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let revokeJSON = #"{}"#
        let installJSON = #"{"installation_handle":"new-handle","endpoint_epoch":1,"expires_at":1700086400}"#
        let challenge2JSON = #"{"challenge_id":"ch-2","challenge":"nonce2","expires_at":1700000600}"#
        let delegationJSON = #"{"endpoint_grant":"grant-1"}"#
        let transport = ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),   // enroll challenge
            (Data(conflictJSON.utf8), 409),     // install → 409 without handle
            (Data(revokeJSON.utf8), 200),       // revoke using stashed handle
            (Data(installJSON.utf8), 201),      // retry install → success
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

        // The revoke call used the stashed handle.
        let revokeRequest = transport.requests[2]
        #expect(revokeRequest.url.path.hasSuffix("/v1/installations/revoke"))
        let revokeBody = try JSONSerialization.jsonObject(with: revokeRequest.body) as? [String: Any]
        #expect(revokeBody?["installation_handle"] as? String == "stashed-handle")

        // Pending handle was cleaned up.
        #expect(store.loadPendingHandle(communityID: "comm-1") == nil)

        // Final enrollment uses the new handle.
        let enrollment = store.load(communityID: "comm-1")
        #expect(enrollment?.installationHandle == "new-handle")
    }

    @Test("Revoke calls gateway revoke endpoint")
    func revokeCallsGateway() async throws {
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

        let revokeJSON = #"{}"#
        let transport = ScriptedTransport(responses: [
            (Data(revokeJSON.utf8), 200),  // gateway revoke
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

        await driver.revoke()

        // Gateway revoke was called with the right handle.
        #expect(transport.requests.count >= 1)
        let revokeRequest = transport.requests[0]
        #expect(revokeRequest.url.path.hasSuffix("/v1/installations/revoke"))
        let revokeBody = try JSONSerialization.jsonObject(with: revokeRequest.body) as? [String: Any]
        #expect(revokeBody?["installation_handle"] as? String == "handle-1")

        // Local enrollment removed.
        #expect(store.load(communityID: "comm-1") == nil)
        let state = await driver.state
        #expect(state == .idle)

        // Successful gateway revoke — no pending handle stashed.
        #expect(store.loadPendingHandle(communityID: "comm-1") == nil)
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

/// A fake App Attest provider for testing.
struct FakeAttestProvider: AppAttestProviding {
    let supported: Bool

    init(supported: Bool) {
        self.supported = supported
    }

    var isSupported: Bool { supported }

    func generateKey() async throws -> String {
        guard supported else { throw FakeAttestError.unsupported }
        return "fake-key-id"
    }

    func attest(keyID _: String, clientDataHash _: Data) async throws -> Data {
        guard supported else { throw FakeAttestError.unsupported }
        return Data("fake-attestation".utf8)
    }

    func assert(keyID _: String, clientDataHash _: Data) async throws -> Data {
        guard supported else { throw FakeAttestError.unsupported }
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

extension ActorBox where T == [NostrEvent] {
    func append(_ event: NostrEvent) {
        value.append(event)
    }
}
