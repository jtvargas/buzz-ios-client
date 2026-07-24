@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("WindowClient fetch and partition")
struct WindowClientTests {
    private let queryURL = URL(string: "https://relay.example.com/query")!

    // MARK: - Valid pages

    @Test("A valid page partitions strictly by kind, rows in received order")
    func partitionsByKind() async throws {
        let build = try WindowResponseBuilder()
        let row1 = try build.row("newest", at: 1_700_000_300)
        let row2 = try build.row("middle", at: 1_700_000_200)
        let row3 = try build.row("oldest", at: 1_700_000_100)
        let reaction = try build.reaction(on: row1.id)
        let edit = try build.edit(of: row2.id, to: "middle (edited)")
        let deletion = try build.deletion(of: row3.id)
        let tombstone = try build.tombstone(of: row2.id)
        let summary = try build.summary(for: row1.id)
        let bounds = try build.headBounds(hasMore: false)

        // Aux and the summary are interleaved among the rows: partition must key off
        // kind, never array position.
        let response = try WindowResponseBuilder.body(
            [row1, reaction, row2, edit, summary, row3, deletion, tombstone, bounds]
        )
        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: build.channel), respondingWith: response, signer: InMemorySigner()
        )

        let page = try requirePage(result)
        // Rows keep their delivered keyset order, aux stripped out from between them.
        #expect(page.rows.map(\.id) == [row1.id, row2.id, row3.id])
        #expect(Set(page.aux.map(\.id)) == Set([reaction.id, edit.id, deletion.id, tombstone.id]))
        #expect(page.summaries.map(\.id) == [summary.id])
        #expect(page.bounds.hasMore == false)
        #expect(page.bounds.nextCursor == nil)
    }

    @Test("has_more true surfaces the next cursor for the reconcile loop")
    func carriesNextCursor() async throws {
        let build = try WindowResponseBuilder()
        let row = try build.row("only", at: 1_700_000_300)
        let next = WindowCursor(createdAt: 1_700_000_050, id: String(repeating: "d", count: 64))
        let bounds = try build.headBounds(hasMore: true, nextCursor: next)
        let response = try WindowResponseBuilder.body([row, bounds])

        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: build.channel), respondingWith: response, signer: InMemorySigner()
        )

        let page = try requirePage(result)
        #expect(page.bounds.hasMore == true)
        #expect(page.bounds.nextCursor == next)
    }

    @Test("An empty but served window is a valid page, not a degradation")
    func emptyServedWindow() async throws {
        let build = try WindowResponseBuilder()
        let bounds = try build.headBounds(hasMore: false)
        let response = try WindowResponseBuilder.body([bounds])

        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: build.channel), respondingWith: response, signer: InMemorySigner()
        )

        let page = try requirePage(result)
        #expect(page.rows.isEmpty)
        #expect(page.bounds.hasMore == false)
    }

    // MARK: - Degradation

    @Test("A transport failure degrades to the WS fallback signal")
    func transportFailureDegrades() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueueFailure(.requestFailed("offline"))
        let client = WindowClient(transport: transport, queryURL: queryURL, signer: try InMemorySigner())

        let result = try await client.fetch(WindowFilter(channelID: "c"))
        #expect(result == .degraded(.transportFailure(.requestFailed("offline"))))
    }

    @Test("A non-2xx status degrades, carrying the status")
    func httpErrorDegrades() async throws {
        let build = try WindowResponseBuilder()
        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: build.channel),
            respondingWith: Data("bad request".utf8), status: 400, signer: InMemorySigner()
        )
        #expect(result == .degraded(.httpStatus(400)))
    }

    @Test("A 2xx body that is not a signed-event array degrades as unreadable")
    func unreadableBodyDegrades() async throws {
        let build = try WindowResponseBuilder()
        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: build.channel),
            respondingWith: Data(#"{"not":"an array"}"#.utf8), signer: InMemorySigner()
        )
        #expect(result == .degraded(.unreadableResponse))
    }

    // MARK: - NIP-98 authentication

    @Test("Each request attaches a fresh, valid NIP-98 header; two requests differ")
    func attachesDistinctNIP98Headers() async throws {
        let build = try WindowResponseBuilder()
        let bounds = try build.headBounds(hasMore: false)
        let response = try WindowResponseBuilder.body([bounds])

        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: response)
        await transport.enqueue(status: 200, body: response)
        let client = WindowClient(transport: transport, queryURL: queryURL, signer: try InMemorySigner())

        _ = try await client.fetch(WindowFilter(channelID: build.channel))
        _ = try await client.fetch(WindowFilter(channelID: build.channel))

        let requests = await transport.requests
        #expect(requests.count == 2)

        for request in requests {
            #expect(request.headers["Content-Type"] == "application/json")
            let header = try #require(request.headers["Authorization"])
            // The header authorizes exactly this URL, method, and body — the payload
            // tag hashes the bytes actually sent.
            #expect(NIP98.validate(header: header, url: queryURL, method: "POST", body: request.body))
        }

        // A fresh nonce per request means two otherwise-identical fetches never
        // carry the same Authorization value — no header is replayable.
        #expect(requests[0].headers["Authorization"] != requests[1].headers["Authorization"])
    }

    // MARK: - Helpers

    private func requirePage(_ result: WindowResult) throws -> WindowPage {
        guard case let .page(page) = result else {
            Issue.record("expected a valid page, got \(result)")
            throw CancellationError()
        }
        return page
    }
}
