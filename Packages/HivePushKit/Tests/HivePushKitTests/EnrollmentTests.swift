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

    private static let gatewayA = URL(string: "http://gateway-a.test:3005")!
    private static let gatewayB = URL(string: "http://gateway-b.test:3005")!
    private static let enrolledAt = Date(timeIntervalSince1970: 1_760_000_000)

    private func enrollment(
        communityID: String = UUID().uuidString,
        installationHandle: String = "handle-1",
        endpointGrant: String = "grant-1",
        gatewayURL: URL? = EnrollmentStoreTests.gatewayA
    ) -> Enrollment {
        Enrollment(
            communityID: communityID,
            installationHandle: installationHandle,
            endpointGrant: endpointGrant,
            attestKeyID: "key-1",
            installID: UUID().uuidString,
            relayURL: "wss://relay.example",
            gatewayURL: gatewayURL,
            enrolledAt: Self.enrolledAt
        )
    }

    private func pending(
        communityID: String,
        gatewayURL: URL = EnrollmentStoreTests.gatewayA,
        handle: String = "h-1",
        expiresAt: Date = .distantFuture
    ) -> PendingRevocation {
        PendingRevocation(
            communityID: communityID,
            gatewayURL: gatewayURL,
            installationHandle: handle,
            attestKeyID: "k-\(handle)",
            installationExpiresAt: expiresAt
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

    @Test("Remove clears one enrollment, and only while it still has the given handle")
    func removeOne() throws {
        let (store, _) = makeStore()
        let e1 = enrollment(communityID: "a", installationHandle: "h-1")
        let e2 = enrollment(communityID: "b")
        try store.write(e1)
        try store.write(e2)
        // A newer installation replaced the one the caller read: it is not theirs to drop.
        store.remove(communityID: "a", installationHandle: "h-0")
        #expect(store.load(communityID: "a") == e1)
        store.remove(communityID: "a", installationHandle: "h-1")
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

    @Test("An enrollment written before gatewayURL existed still loads, with no gateway")
    func legacyEnrollmentDecodes() throws {
        let (store, container) = makeStore()
        let directory = container.appendingPathComponent("PushEnrollments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
            {"communityID":"c1","installationHandle":"h-1","endpointGrant":"g-1","attestKeyID":"k-1",
             "installID":"i-1","relayURL":"wss://relay.example","enrolledAt":"2025-10-09T08:53:20Z"}
            """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("c1.json"))

        let loaded = try #require(store.load(communityID: "c1"))
        #expect(loaded.installationHandle == "h-1")
        #expect(loaded.gatewayURL == nil)
        #expect(loaded.enrolledAt == Self.enrolledAt)
    }

    @Test("Pending revocation round-trips with gateway, handle, key and expiry")
    func pendingRevocationRoundTrip() throws {
        let (store, _) = makeStore()
        #expect(store.loadAllPendingRevocations().isEmpty)
        let record = pending(communityID: "c1", handle: "h-99", expiresAt: Self.enrolledAt)
        try store.savePendingRevocation(record)
        #expect(store.loadAllPendingRevocations() == [record])
        store.removePendingRevocation(record)
        #expect(store.loadAllPendingRevocations().isEmpty)
    }

    @Test("One community keeps a pending record per installation: gateways and handles never overwrite each other")
    func pendingRecordsAreKeyedByInstallation() throws {
        let (store, _) = makeStore()
        let onA = pending(communityID: "c1", gatewayURL: Self.gatewayA, handle: "h-1")
        let onB = pending(communityID: "c1", gatewayURL: Self.gatewayB, handle: "h-1")
        let laterOnA = pending(communityID: "c1", gatewayURL: Self.gatewayA, handle: "h-2")
        try store.savePendingRevocation(onA)
        try store.savePendingRevocation(onB)
        try store.savePendingRevocation(laterOnA)
        #expect(Set(store.loadAllPendingRevocations()) == [onA, onB, laterOnA])
        #expect(Set(store.loadAllPendingRevocations(gatewayURL: Self.gatewayA)) == [onA, laterOnA])

        // Settling one leaves the community's other installations pending.
        store.removePendingRevocation(onA)
        #expect(Set(store.loadAllPendingRevocations()) == [onB, laterOnA])
        // Saving the same installation again is an overwrite, not a duplicate.
        try store.savePendingRevocation(onB)
        #expect(store.loadAllPendingRevocations().count == 2)
    }

    @Test("Demote moves an enrollment's credentials into the pending set with its expiry")
    func demoteToPendingRevocation() throws {
        let (store, _) = makeStore()
        let e = enrollment(communityID: "c1", installationHandle: "h-1")
        try store.write(e)
        let demoted = try store.demoteToPendingRevocation(communityID: "c1", gatewayURL: nil)
        let record = try #require(demoted)
        #expect(store.load(communityID: "c1") == nil)
        #expect(store.loadAllPendingRevocations() == [record])
        #expect(record == PendingRevocation(enrollment: e, gatewayURL: Self.gatewayA))
        #expect(record.gatewayURL == Self.gatewayA)
        // Upper bound on the gateway's expires_at: install and delegation
        // expiries are both now + defaultDuration, taken before enrolledAt.
        #expect(record.installationExpiresAt == Self.enrolledAt.addingTimeInterval(NIPPLLease.defaultDuration))

        // No enrollment: nothing is written.
        #expect(try store.demoteToPendingRevocation(communityID: "c2", gatewayURL: Self.gatewayA) == nil)
        #expect(store.loadAllPendingRevocations() == [record])
    }

    @Test("Demote scopes to the enrollment's own gateway, falling back to the caller's only for legacy records")
    func demoteGatewayPrecedence() throws {
        let (store, _) = makeStore()
        // The enrollment knows its gateway: the caller's (stale) URL is ignored.
        try store.write(enrollment(communityID: "c1", gatewayURL: Self.gatewayA))
        let c1 = try store.demoteToPendingRevocation(communityID: "c1", gatewayURL: Self.gatewayB)
        #expect(c1?.gatewayURL == Self.gatewayA)

        // Legacy enrollment without a gateway: the caller's URL is used.
        try store.write(enrollment(communityID: "c2", gatewayURL: nil))
        let c2 = try store.demoteToPendingRevocation(communityID: "c2", gatewayURL: Self.gatewayB)
        #expect(c2?.gatewayURL == Self.gatewayB)
        #expect(Set(store.loadAllPendingRevocations().map(\.communityID)) == ["c1", "c2"])

        // Neither knows: refuse, and keep the enrollment rather than write an unscoped record.
        let e3 = enrollment(communityID: "c3", gatewayURL: nil)
        try store.write(e3)
        #expect(throws: EnrollmentStoreError.gatewayUnknown) {
            try store.demoteToPendingRevocation(communityID: "c3", gatewayURL: nil)
        }
        #expect(store.load(communityID: "c3") == e3)
        #expect(store.loadAllPendingRevocations().count == 2)
    }

    @Test("Demote keeps the enrollment when the pending record cannot be written")
    func demoteKeepsEnrollmentOnWriteFailure() throws {
        let (store, container) = makeStore()
        let e = enrollment(communityID: "c1")
        try store.write(e)
        // A plain file where the pending directory must go makes every pending write fail.
        try Data().write(to: container.appendingPathComponent("PushPendingRevocations"))

        #expect(throws: (any Error).self) {
            try store.demoteToPendingRevocation(communityID: "c1", gatewayURL: nil)
        }
        #expect(store.load(communityID: "c1") == e)
        #expect(store.loadAllPendingRevocations().isEmpty)
    }

    @Test("LoadAllPendingRevocations spans communities but never gateways")
    func loadAllPending() throws {
        let (store, _) = makeStore()
        #expect(store.loadAllPendingRevocations(gatewayURL: Self.gatewayA).isEmpty)
        try store.savePendingRevocation(pending(communityID: "a", gatewayURL: Self.gatewayA, handle: "h-a"))
        try store.savePendingRevocation(pending(communityID: "b", gatewayURL: Self.gatewayA, handle: "h-b"))
        try store.savePendingRevocation(pending(communityID: "c", gatewayURL: Self.gatewayB, handle: "h-c"))
        let forA = Set(store.loadAllPendingRevocations(gatewayURL: Self.gatewayA).map(\.installationHandle))
        #expect(forA == ["h-a", "h-b"])
        let forB = Set(store.loadAllPendingRevocations(gatewayURL: Self.gatewayB).map(\.installationHandle))
        #expect(forB == ["h-c"])
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
