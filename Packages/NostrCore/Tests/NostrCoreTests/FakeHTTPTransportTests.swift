import Foundation
@testable import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("FakeHTTPTransport scripted-transport contract")
struct FakeHTTPTransportTests {
    private let url = URL(string: "https://relay.example.com/query")!

    // MARK: - Scripted responses

    @Test("A scripted 2xx response is returned body-and-status")
    func scriptedSuccess() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: #"["EVENT"]"#)

        let (body, status) = try await transport.post(body: Data(), to: url, headers: [:])
        #expect(status == 200)
        #expect(body == Data(#"["EVENT"]"#.utf8))
    }

    @Test("A non-2xx status is passed through as a result, not thrown")
    func nonSuccessStatusPassthrough() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 404, body: "not found")

        // The seam reports the status; interpreting 404 is the caller's job, so
        // the post resolves rather than throwing.
        let (body, status) = try await transport.post(body: Data(), to: url, headers: [:])
        #expect(status == 404)
        #expect(body == Data("not found".utf8))
    }

    @Test("A scripted transport error ends the post")
    func scriptedFailureThrows() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueueFailure(.requestFailed("offline"))

        await #expect(throws: TransportError.requestFailed("offline")) {
            _ = try await transport.post(body: Data(), to: url, headers: [:])
        }
    }

    // MARK: - Request recording

    @Test("Every request is recorded with its url, body, and headers")
    func recordsRequests() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: Data())
        let body = Data(#"[{"kinds":[9]}]"#.utf8)
        let headers = ["Authorization": "Nostr abc", "Content-Type": "application/json"]

        _ = try await transport.post(body: body, to: url, headers: headers)

        let recorded = await transport.requests
        #expect(recorded == [FakeHTTPTransport.RecordedRequest(url: url, body: body, headers: headers)])
    }

    @Test("Scripted responses are consumed in order, one per post")
    func responsesConsumedInOrder() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: "page-1")
        await transport.enqueue(status: 200, body: "page-2")

        let (firstBody, _) = try await transport.post(body: Data(), to: url, headers: [:])
        let (secondBody, _) = try await transport.post(body: Data(), to: url, headers: [:])
        #expect(firstBody == Data("page-1".utf8))
        #expect(secondBody == Data("page-2".utf8))
        // The whole script was consumed; nothing was invented or left over.
        #expect(await transport.pendingCount == 0)
    }

    @Test("A post parked before its response is scripted resolves to that response")
    func parkedPostResolves() async throws {
        let transport = FakeHTTPTransport()

        // Issue the request before scripting anything; whichever order the
        // runtime interleaves these, the outcome is fixed.
        async let response = transport.post(body: Data(), to: url, headers: [:])
        await transport.enqueue(status: 201, body: "created")

        let (body, status) = try await response
        #expect(status == 201)
        #expect(body == Data("created".utf8))
        #expect(await transport.pendingCount == 0)
    }
}
