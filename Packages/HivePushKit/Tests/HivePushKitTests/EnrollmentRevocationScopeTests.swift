import Foundation
@testable import HivePushKit
import NostrCore
import Testing

// MARK: - EnrollmentDriver revocation scoping

/// What `EnrollmentDriver.revoke()` is allowed to touch. A revoke is about one
/// installation: it goes to the gateway that issued it, and once it lands it
/// may only clear that installation's own records — never an enrollment that
/// replaced it while the request was in flight.
@Suite("Enrollment driver revocation scoping", .timeLimit(.minutes(1)))
struct EnrollmentRevocationScopeTests {
    private static let gatewayURL = URL(string: "http://gateway.test:3005")!
    private static let otherGatewayURL = URL(string: "http://other-gateway.test:3005")!
    private static let enrolledAt = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeStoreWithContainer() -> (EnrollmentStore, URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnrollmentRevocationScopeTests-\(UUID().uuidString)", isDirectory: true)
        return (EnrollmentStore(containerURL: container), container)
    }

    private func enrollment(handle: String = "handle-1", gatewayURL: URL? = gatewayURL) -> Enrollment {
        Enrollment(
            communityID: "comm-1",
            installationHandle: handle,
            endpointGrant: "grant-\(handle)",
            attestKeyID: "key-\(handle)",
            installID: "install-\(handle)",
            relayURL: "wss://relay.example",
            gatewayURL: gatewayURL,
            enrolledAt: Self.enrolledAt
        )
    }

    /// A driver for community `comm-1`, bound to `gatewayURL`.
    private func makeDriver(
        store: EnrollmentStore,
        transport: ScriptedTransport,
        gatewayURL: URL = gatewayURL
    ) throws -> EnrollmentDriver {
        EnrollmentDriver(
            gateway: GatewayClient(baseURL: gatewayURL, transport: transport),
            attestProvider: FakeAttestProvider(supported: true),
            enrollmentStore: store,
            signer: try InMemorySigner(),
            communityID: "comm-1",
            relayURL: "wss://relay.example",
            relayPubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            executorKeyID: "relay-v1",
            origin: "wss://relay.example",
            publishEvent: { _ in }
        )
    }

    /// Challenge then confirmed revoke.
    private func revokeSucceeds() -> ScriptedTransport {
        let challengeJSON = #"{"challenge_id":"ch-r","challenge":"nonce-r","expires_at":1700000300}"#
        return ScriptedTransport(responses: [
            (Data(challengeJSON.utf8), 200),
            (Data(#"{"status":"revoked"}"#.utf8), 200),
        ])
    }

    @Test("Revoke goes to the gateway that issued the installation, not the one the driver was built for")
    func revokeUsesEnrollmentGateway() async throws {
        let (store, _) = makeStoreWithContainer()
        // Enrolled on the test gateway; the community's URL has since moved.
        try store.write(enrollment())
        let transport = revokeSucceeds()
        let driver = try makeDriver(store: store, transport: transport, gatewayURL: Self.otherGatewayURL)

        await driver.revoke()

        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.url.host == Self.gatewayURL.host })
        #expect(store.load(communityID: "comm-1") == nil)
        #expect(store.loadAllPendingRevocations().isEmpty)
    }

    @Test("A legacy enrollment with no recorded gateway is revoked on the driver's")
    func revokeLegacyEnrollmentUsesDriverGateway() async throws {
        let (store, _) = makeStoreWithContainer()
        try store.write(enrollment(gatewayURL: nil))
        // Unreachable: the pending record must name the gateway the revoke was sent to.
        let transport = ScriptedTransport(responses: [])
        let driver = try makeDriver(store: store, transport: transport, gatewayURL: Self.otherGatewayURL)

        await driver.revoke()

        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url.host == Self.otherGatewayURL.host)
        #expect(store.loadAllPendingRevocations().map(\.gatewayURL) == [Self.otherGatewayURL])
    }

    @Test("A revoke that lands after a re-enrollment settles only its own installation")
    func delayedRevokeLeavesNewerEnrollmentAlone() async throws {
        let (store, _) = makeStoreWithContainer()
        try store.write(enrollment())
        let newer = enrollment(handle: "handle-2")
        let transport = revokeSucceeds()
        // While the revoke is on the wire, the user re-enables push: a new
        // installation is written for the same community.
        transport.onRequest = { request in
            guard request.url.path.hasSuffix("/v1/installations/revoke") else { return }
            try? store.write(newer)
        }
        let driver = try makeDriver(store: store, transport: transport)

        await driver.revoke()

        #expect(transport.requests.count == 2)
        #expect(store.load(communityID: "comm-1") == newer)
        #expect(store.loadAllPendingRevocations().isEmpty)
    }

    @Test("A revoke with no pending record that lands after a re-enrollment still leaves the newer one alone")
    func delayedRevokeWithoutPendingRecordLeavesNewerEnrollmentAlone() async throws {
        let (store, container) = makeStoreWithContainer()
        try store.write(enrollment())
        // A plain file where the pending directory must go makes every pending write fail.
        try Data().write(to: container.appendingPathComponent("PushPendingRevocations"))
        let newer = enrollment(handle: "handle-2")
        let transport = revokeSucceeds()
        transport.onRequest = { request in
            guard request.url.path.hasSuffix("/v1/installations/revoke") else { return }
            try? store.write(newer)
        }
        let driver = try makeDriver(store: store, transport: transport)

        await driver.revoke()

        #expect(transport.requests.count == 2)
        #expect(store.load(communityID: "comm-1") == newer)
    }
}
