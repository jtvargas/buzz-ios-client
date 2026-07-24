@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Parses a **real** populated `POST /query` NIP-CW window captured from the Buzz Pi
/// relay, end to end through the client to a validated ``WindowPage``.
///
/// # Fixture provenance — REAL PI CAPTURE
///
/// `Fixtures/window-head-response-pi.json` was captured by the step-7 live integration
/// suite (`LivePiIntegrationTests`) against `https://homelab.tail4bc643.ts.net/query`,
/// with a throwaway member key on a self-provisioned channel
/// (`867c6929-7d06-4329-9b46-7a6035fe7a71`) after seven top-level messages were
/// published. It is the genuine relay response, only reformatted (pretty-printed,
/// keys sorted) — no field of any event was altered, so every signature still verifies.
///
/// This closes the open item the synthetic `window-head-response.json` was standing in
/// for. It confirms three facts the Phase-2 design assumed:
///
/// 1. The Pi **does** serve the NIP-CW window fast path on `/query` for a member — the
///    response carries a relay-signed `kind:39006` bounds overlay, so the engine takes
///    the fast path rather than degrading to WebSocket assembly.
/// 2. The bounds overlay's `d`-tag binding is exactly `<channel>:head` for a head
///    request, and it is signed by the relay's advertised key
///    (`0b9776…88b7`, the NIP-11 `self`).
/// 3. The response is the flat signed-event array NIP-CW §Response describes, mixing the
///    kind-9 rows and the kind-39006 overlay in one array — which the client partitions
///    by kind, never by position.
struct WindowPiFixtureTests {
    /// The channel the capture was taken against; the bounds overlay's `d` tag binds to
    /// it, so the request must name the same channel to validate.
    private let channel = "867c6929-7d06-4329-9b46-7a6035fe7a71"

    private func fixtureBody() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "window-head-response-pi", withExtension: "json"),
            "the Pi window fixture resource must be bundled"
        )
        return try Data(contentsOf: url)
    }

    @Test("The real Pi head response parses into a valid, exhausted page")
    func parsesRealPiWindow() async throws {
        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: channel),
            respondingWith: try fixtureBody(),
            signer: try InMemorySigner()
        )

        guard case let .page(page) = result else {
            Issue.record("the real Pi window must parse to a valid page, got \(result)")
            return
        }

        // Seven top-level kind-9 rows, no aux, no summaries, and an exhausted head.
        #expect(page.rows.count == 7)
        #expect(page.rows.allSatisfy { $0.kind == .channelMessage })
        #expect(page.rows.allSatisfy { $0.groupID == channel })
        #expect(page.aux.isEmpty)
        #expect(page.summaries.isEmpty)
        #expect(page.bounds.hasMore == false)
        #expect(page.bounds.nextCursor == nil)
    }

    @Test("The captured rows are genuinely signed, so they survive the ingest choke point")
    func rowsVerify() throws {
        let events = try JSONDecoder().decode([NostrEvent].self, from: fixtureBody())
        // The kind-9 rows are ordinary signed events the engine ingests; the relay-signed
        // kind-39006 overlay is not verified under the authenticated-transport profile.
        let rows = events.filter { $0.kind == .channelMessage }
        #expect(rows.count == 7)
        let allValid = rows.allSatisfy(\.isValid)
        #expect(allValid)

        // The bounds overlay is signed by the relay's advertised key, not a member's.
        let bounds = try #require(events.first { $0.kind == .windowBounds })
        #expect(bounds.pubkey == "0b9776697459f1ceae1d1fac11ffd5db9e170803a91e87f8fd020631e69788b7")
    }
}
