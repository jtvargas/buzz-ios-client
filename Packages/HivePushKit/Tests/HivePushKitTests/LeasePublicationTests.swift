import Foundation
@testable import HivePushKit
import NostrCore
import Testing

@Suite("Lease publication contract")
struct LeasePublicationTests {
    private func executorKey() throws -> PrivateKey {
        try PrivateKey(hex: String(repeating: "0", count: 63) + "1")
    }

    @Test("Lease decrypts at the executor and carries the closed relay schema")
    func wireContract() async throws {
        let executor = try executorKey()
        let signer = try InMemorySigner()
        let author = try await signer.publicKey()
        let expiration = Date().addingTimeInterval(600)
        let event = try await NIPPLLease.create(
            installID: UUID().uuidString,
            destination: .init(
                origin: "wss://canonical.example", keyID: "executor-2", publicKey: executor.publicKey,
                appProfile: "buzz-ios-dogfood", endpointGrant: "opaque-grant"
            ),
            filters: NIPPLLease.defaultFilters(selfPubkey: author.hex),
            expiration: expiration, signer: signer
        )
        #expect(event.tags.count == 3)
        #expect(event.tags.allSatisfy { $0.count == 2 })
        #expect(event.tags.filter { $0.first == "exec" } == [["exec", "executor-2"]])
        let plaintext = try NIP44.decrypt(
            event.content,
            conversationKey: NIP44.conversationKey(privateKey: executor, peer: author)
        )
        let body = try #require(JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])
        #expect(Set(body.keys) == Set([
            "v",
            "origin",
            "app_profile",
            "transport",
            "endpoint",
            "generation",
            "active",
            "subscriptions",
        ]))
        #expect(body["origin"] as? String == "wss://canonical.example")
        #expect(body["endpoint"] as? String == "opaque-grant")
        #expect(body["generation"] as? Int == 1)
        #expect(body["transport"] as? String == "apns")
        #expect(body["active"] as? Bool == true)
        let subscriptions = try #require(body["subscriptions"] as? [[String: Any]])
        #expect(!subscriptions.isEmpty)
        for subscription in subscriptions {
            #expect(Set(subscription.keys) == Set(["filter", "class"]))
            #expect(subscription["class"] as? String == "default")
            let filter = try #require(subscription["filter"] as? [String: Any])
            #expect(filter["#p"] as? [String] == [author.hex])
            let kinds = try #require(filter["kinds"] as? [Int])
            #expect(Set(kinds).isSubset(of: [9, 40002, 45001, 45003]))
        }
        await #expect(throws: (any Error).self) { try await signer.decryptToSelf(event.content) }
    }

    @Test("Rate limit retries and later sessions reuse the persisted signed lease")
    func retryAndResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnrollmentStore(containerURL: directory)
        let enrollment = try Enrollment(
            communityID: "community", installationHandle: "handle", endpointGrant: "grant",
            attestKeyID: "key", installID: UUID().uuidString,
            relayURL: "wss://relay.example", gatewayURL: #require(URL(string: "https://gateway.example"))
        )
        try store.write(enrollment)
        let probe = PublicationProbe()
        let signer = try InMemorySigner()
        let executor = try executorKey()
        func driver() -> EnrollmentDriver {
            EnrollmentDriver(
                gateway: GatewayClient(baseURL: enrollment.gatewayURL!, transport: ScriptedTransport(responses: [])),
                attestProvider: FakeAttestProvider(supported: true), enrollmentStore: store,
                signer: signer, communityID: "community", relayURL: enrollment.relayURL,
                relayPubkey: executor.publicKey.hex, executorKeyID: "relay-v1", origin: "wss://canonical.example",
                retrySleep: { await probe.slept($0) },
                publishEvent: { event in
                    #expect(store.load(communityID: "community")?.leaseEvent == event)
                    try await probe.publish(event)
                }
            )
        }
        let first = driver()
        await first.enroll(
            requestPermission: { Issue.record("Stored enrollment must skip permission"); return false },
            registerForRemoteNotifications: {}
        )
        #expect(await first.state == .enrolled)
        let second = driver()
        await second.enroll(requestPermission: { false }, registerForRemoteNotifications: {})
        #expect(await second.state == .enrolled)
        let events = await probe.events
        #expect(events.count == 3)
        #expect(Set(events.map(\.id)).count == 1)
        #expect(await probe.delays == [.seconds(4)])
    }
    @Test("Invalid refusals stop immediately and quota retries are bounded", arguments: [0, 1, 2])
    func boundedFailures(mode: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnrollmentStore(containerURL: directory)
        try store.write(Enrollment(
            communityID: "community", installationHandle: "handle", endpointGrant: "grant",
            attestKeyID: "key", installID: UUID().uuidString,
            relayURL: "wss://relay.example", gatewayURL: URL(string: "https://gateway.example")!
        ))
        let reasons: [OKReason] = [.invalid("bad lease"), .rateLimited("retry in 4s"), .rateLimited("retry in 999s")]
        let probe = PublicationProbe(failureLimit: 100, reason: reasons[mode])
        let driver = EnrollmentDriver(
            gateway: GatewayClient(
                baseURL: URL(string: "https://gateway.example")!, transport: ScriptedTransport(responses: [])
            ),
            attestProvider: FakeAttestProvider(supported: true), enrollmentStore: store,
            signer: try InMemorySigner(), communityID: "community", relayURL: "wss://relay.example",
            relayPubkey: try executorKey().publicKey.hex, executorKeyID: "relay-v1", origin: "wss://relay.example",
            retrySleep: { await probe.slept($0) }, publishEvent: { try await probe.publish($0) }
        )
        await driver.enroll(requestPermission: { false }, registerForRemoteNotifications: {})
        guard case .failed(.publishLease, _) = await driver.state else {
            Issue.record("Expected publication failure")
            return
        }
        #expect(await probe.events.count == (mode == 1 ? 3 : 1))
        #expect(await probe.delays.count == (mode == 1 ? 2 : 0))
    }

}

private actor PublicationProbe {
    let failureLimit: Int
    let reason: OKReason
    init(failureLimit: Int = 1, reason: OKReason = .rateLimited("quota exceeded; retry in 4s")) {
        self.failureLimit = failureLimit
        self.reason = reason
    }
    var events: [NostrEvent] = []
    var delays: [Duration] = []
    func slept(_ delay: Duration) {
        delays.append(delay)
    }

    func publish(_ event: NostrEvent) throws {
        events.append(event)
        if events.count <= failureLimit {
            throw RelayConnectionError.publishRejected(reason)
        }
    }
}
