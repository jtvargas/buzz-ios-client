import Foundation
import HivePushKit
import NostrCore
import OSLog
import Testing

@Suite("Lease-gated push wakes")
struct PushWakeResolverTests {
    private let now = Date(timeIntervalSince1970: 100)

    @Test("Only active unexpired leases with usable subscriptions reach the relay")
    func eligibility() async throws {
        let transport = WakeTransport()
        let reader = try InMemorySigner()
        let future = now.addingTimeInterval(1)
        let valid: [[String: Any]] = [["kinds": [9], "#h": ["channel"]]]
        let communities = try [
            pushCommunity(id: "inactive", leaseExpiresAt: future, subscriptionFilters: valid),
            pushCommunity(id: "expired", leaseActive: true, leaseExpiresAt: now.addingTimeInterval(-1),
                          subscriptionFilters: valid),
            pushCommunity(id: "boundary", leaseActive: true, leaseExpiresAt: now, subscriptionFilters: valid),
            pushCommunity(id: "no-expiry", leaseActive: true, subscriptionFilters: valid),
            pushCommunity(id: "no-filters", leaseActive: true, leaseExpiresAt: future),
            pushCommunity(id: "empty-filters", leaseActive: true, leaseExpiresAt: future, subscriptionFilters: []),
            pushCommunity(id: "malformed", leaseActive: true, leaseExpiresAt: future,
                          subscriptionFilters: [["kinds": "9"]]),
            pushCommunity(id: "unknown-selector", leaseActive: true, leaseExpiresAt: future,
                          subscriptionFilters: [["future-selector": ["private-channel"]]]),
            pushCommunity(id: "eligible", leaseActive: true, leaseExpiresAt: future, subscriptionFilters: valid),
        ]
        let resolver = PushWakeResolver(client: PushQueryClient(transport: transport), signer: { _ in reader },
                                        now: { now })
        await resolver.resolve(communities: communities) { _ in Issue.record("Empty results cannot produce a preview") }
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let filters = try JSONDecoder().decode([Filter].self, from: request)
        #expect(filters == [Filter(kinds: [9], limit: 10, tagQueries: ["h": ["channel"]])])
    }

    @Test("A failed community does not prevent another community's verified preview")
    func partialFailure() async throws {
        let sender = try InMemorySigner()
        let reader = try InMemorySigner()
        let event = try await pushMessage(sender: sender, content: "Incoming")
        let transport = WakeTransport(body: try JSONEncoder().encode([event]), failFirst: true)
        let communities = try ["a", "b"].map {
            try pushCommunity(id: $0, leaseActive: true, leaseExpiresAt: now.addingTimeInterval(1),
                              subscriptionFilters: [["kinds": [9], "#h": ["channel"]]])
        }
        let previews = OSAllocatedUnfairLock(initialState: [PushNotification]())
        let resolver = PushWakeResolver(client: PushQueryClient(transport: transport), signer: { _ in reader },
                                        now: { now })
        await resolver.resolve(communities: communities) { preview in previews.withLock { $0.append(preview) } }
        #expect(await transport.requests.count == 2)
        #expect(previews.withLock { $0.map(\.target.communityID) } == ["b"])
        #expect(previews.withLock { $0.first?.target.eventID } == event.id)
    }

    @Test("Expiry while a query is in flight suppresses its preview")
    func expiryDuringQuery() async throws {
        let event = try await pushMessage(sender: InMemorySigner())
        let reader = try InMemorySigner()
        let clock = OSAllocatedUnfairLock(initialState: now)
        let expiry = now.addingTimeInterval(1)
        let transport = WakeTransport(body: try JSONEncoder().encode([event]), beforeResponse: {
            clock.withLock { $0 = expiry }
        })
        let community = try pushCommunity(leaseActive: true, leaseExpiresAt: expiry,
                                          subscriptionFilters: [["kinds": [9]]])
        let resolver = PushWakeResolver(client: PushQueryClient(transport: transport), signer: { _ in reader },
                                        now: { clock.withLock { $0 } })
        await resolver.resolve(communities: [community]) { _ in Issue.record("Expired lease produced a preview") }
        #expect(await transport.requests.count == 1)
    }

    @Test("A cancelled wake never queries another community")
    func cancellation() async throws {
        let reader = try InMemorySigner()
        let transport = WakeTransport(beforeResponse: { withUnsafeCurrentTask { $0?.cancel() } })
        let communities = try ["a", "b"].map {
            try pushCommunity(id: $0, leaseActive: true, leaseExpiresAt: now.addingTimeInterval(1),
                              subscriptionFilters: [["kinds": [9]]])
        }
        let resolver = PushWakeResolver(client: PushQueryClient(transport: transport), signer: { _ in reader },
                                        now: { now })
        await Task {
            await resolver.resolve(communities: communities) { _ in Issue.record("Cancelled wake produced a preview") }
        }.value
        #expect(await transport.requests.count == 1)
    }
}

private actor WakeTransport: HTTPTransport {
    private(set) var requests: [Data] = []
    let body: Data
    let failFirst: Bool
    let beforeResponse: @Sendable () -> Void

    init(body: Data = Data("[]".utf8), failFirst: Bool = false,
         beforeResponse: @escaping @Sendable () -> Void = {}) {
        self.body = body
        self.failFirst = failFirst
        self.beforeResponse = beforeResponse
    }

    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
        requests.append(body)
        beforeResponse()
        return (self.body, failFirst && requests.count == 1 ? 503 : 200)
    }
}
