import Foundation
import HivePushKit
import NostrCore
import Testing

@Suite("Push relay queries")
struct PushQueryTests {
    @Test("Queries preserve subscription scope and authenticate the exact POST bytes")
    func authenticatedQuery() async throws {
        let signer = try InMemorySigner()
        let pubkey = try await signer.publicKey().hex
        let transport = QueryTransport()
        let client = PushQueryClient(transport: transport)
        let filters = [
            Filter(kinds: [9, 40002, 45001, 45003, 1059], since: 123, limit: 100,
                   tagQueries: ["h": ["channel"], "p": [pubkey]]),
            Filter(authors: [pubkey], kinds: [9], limit: 2),
        ]
        _ = try await client.query(community: pushCommunity(), filters: filters, signer: signer)
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://relay.example/query")
        let queries = try JSONDecoder().decode([Filter].self, from: request.body)
        #expect(queries.count == 2)
        let query = try #require(queries.first)
        #expect(query.kinds == [9, 40002, 45001, 45003])
        #expect(query.limit == 10)
        #expect(query.since == 123)
        #expect(query.tagQueries == ["h": ["channel"], "p": [pubkey]])
        #expect(queries.last?.authors == [pubkey])
        #expect(queries.last?.kinds == [9])
        #expect(queries.last?.limit == 2)
        #expect(request.headers["Content-Type"] == "application/json")
        let header = try #require(request.headers["Authorization"])
        #expect(NIP98.validate(header: header, url: request.url, method: "POST", body: request.body))
        #expect(!NIP98.validate(header: header, url: request.url, method: "POST", body: Data("[]".utf8)))
        let authData = try #require(Data(base64Encoded: String(header.dropFirst("Nostr ".count))))
        let auth = try JSONDecoder().decode(NostrEvent.self, from: authData)
        #expect(auth.pubkey == pubkey)
    }

    @Test("Empty and unsupported subscriptions never become an unrestricted query", arguments: [
        [Filter](), [Filter(kinds: [1059])], [Filter(kinds: [])], [Filter(kinds: [9], limit: 0)],
    ])
    func noEligibleFilters(filters: [Filter]) async throws {
        let transport = QueryTransport()
        let result = try await PushQueryClient(transport: transport).query(
            community: pushCommunity(), filters: filters, signer: InMemorySigner()
        )
        #expect(result == [])
        #expect(await transport.requests.isEmpty)
    }

    @Test("HTTP failures are not interpreted as empty message lists", arguments: [401, 403, 429, 500])
    func httpFailure(status: Int) async throws {
        let transport = QueryTransport(status: status)
        let signer = try InMemorySigner()
        await #expect(throws: PushQueryError.httpStatus(status)) {
            try await PushQueryClient(transport: transport).query(
                community: pushCommunity(), filters: [Filter(kinds: [9])], signer: signer
            )
        }
    }

    @Test("Malformed successful responses fail rather than building a preview")
    func malformedResponse() async throws {
        let transport = QueryTransport(body: Data(#"{"events":[]}"#.utf8))
        let signer = try InMemorySigner()
        await #expect(throws: PushQueryError.unreadableResponse) {
            try await PushQueryClient(transport: transport).query(
                community: pushCommunity(), filters: [Filter(kinds: [9])], signer: signer
            )
        }
    }

    @Test("Cancellation before a wake query prevents signing and network work")
    func cancelledQuery() async throws {
        let transport = QueryTransport()
        let signer = try InMemorySigner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PushQueryClient(transport: transport).query(
                community: pushCommunity(), filters: [Filter(kinds: [9])], signer: signer
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.isEmpty)
    }

    @Test("A signed relay response resolves into the original exact message")
    func queryToPresentation() async throws {
        let sender = try InMemorySigner()
        let reader = try InMemorySigner()
        let event = try await pushMessage(sender: sender, content: "Actual relay message")
        let transport = QueryTransport(body: try JSONEncoder().encode([event]))
        let events = try await PushQueryClient(transport: transport).query(
            community: pushCommunity(), filters: [Filter(kinds: [9], tagQueries: ["h": ["channel"]])],
            signer: reader
        )
        let notification = try #require(PushNotification.build(
            events: events, community: pushCommunity(), selfPubkey: try await reader.publicKey().hex
        ))
        #expect(notification.body == "Actual relay message")
        #expect(notification.target.eventID == event.id)
        #expect(notification.target.createdAt == event.createdAt)
    }
}

private actor QueryTransport: HTTPTransport {
    struct Request: Sendable {
        let body: Data
        let url: URL
        let headers: [String: String]
    }

    private(set) var requests: [Request] = []
    let body: Data
    let status: Int

    init(body: Data = Data("[]".utf8), status: Int = 200) {
        self.body = body
        self.status = status
    }

    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
        requests.append(Request(body: body, url: url, headers: headers))
        return (self.body, status)
    }
}

func pushCommunity(id: String = "community") -> PushCommunitySnapshot {
    PushCommunitySnapshot(
        communityID: id, name: "Test community",
        relayURL: URL(string: "wss://relay.example")!,
        gatewayURL: URL(string: "https://relay.example")!,
        keychainAccount: "hive.identity.\(id)", updatedAt: Date(timeIntervalSince1970: 100)
    )
}

func pushMessage(
    sender: InMemorySigner,
    content: String = "Message",
    kind: EventKind = 9,
    timestamp: Int64 = 100,
    tags: [[String]] = [["h", "channel"]]
) async throws -> NostrEvent {
    try await sender.sign(kind: kind, content: content, tags: tags,
                          createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}
