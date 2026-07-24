@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Parses a captured-shape `POST /query` head-window response end to end, from raw
/// bytes on disk through the client to a validated ``WindowPage``.
///
/// # Fixture provenance — SYNTHETIC
///
/// `Fixtures/window-head-response.json` is **synthetic**, built to the shape
/// NIP-CW §Request / §Overlay Event Formats documents, with real BIP-340
/// signatures over fixed test keys (rows and client aux signed by a synthetic
/// member identity; the `39005`/`39006` overlays and the `9005` tombstone by a
/// synthetic relay identity). It is *not* the Buzz Pi's relay identity.
///
/// A real *populated* capture now exists alongside this synthetic one:
/// `Fixtures/window-head-response-pi.json`, taken by the step-7 live integration suite
/// against the Pi on a self-provisioned channel with a member key (see
/// `WindowPiFixtureTests`). It confirmed the Pi serves the NIP-CW window fast path with
/// a relay-signed `kind:39006` bounds overlay bound `<channel>:head`. This synthetic
/// fixture is retained because it exercises the fuller aux/summary partitioning (a
/// reaction, an edit, an author deletion, a relay tombstone, and a thread summary) that
/// the throwaway-channel capture had no occasion to produce.
@Suite("Window fixture parse")
struct WindowFixtureTests {
    private let channel = "2f8a1c4e-6b3d-4a9f-8e21-0c5d7b9a1e34"

    private func fixtureBody() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "window-head-response", withExtension: "json"),
            "the window fixture resource must be bundled"
        )
        return try Data(contentsOf: url)
    }

    @Test("The captured-shape head response parses into a fully partitioned page")
    func parsesFixture() async throws {
        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: channel),
            respondingWith: try fixtureBody(),
            signer: try InMemorySigner()
        )

        guard case let .page(page) = result else {
            Issue.record("fixture must parse to a valid page, got \(result)")
            return
        }

        // Three top-level kind-9 rows, newest first.
        #expect(page.rows.count == 3)
        #expect(page.rows.allSatisfy { $0.kind == .channelMessage })
        #expect(page.rows.map(\.createdAt) == [1_700_000_300, 1_700_000_200, 1_700_000_100])

        // The aux closure: reaction, edit, author deletion, relay tombstone.
        #expect(page.aux.count == 4)
        #expect(Set(page.aux.map(\.kind)) == [.reaction, .messageEdit, .deletion, .groupDeleteEvent])

        // One thread summary, one exhausted bounds overlay.
        #expect(page.summaries.count == 1)
        #expect(page.summaries.allSatisfy { $0.kind == .threadSummary })
        #expect(page.bounds.hasMore == false)
        #expect(page.bounds.nextCursor == nil)
    }

    @Test("The fixture's rows and aux are genuinely signed, ready for the ingest choke point")
    func fixtureEventsVerify() throws {
        let events = try JSONDecoder().decode([NostrEvent].self, from: fixtureBody())
        // The overlays (39005/39006) are relay-signed and not verified under the
        // authenticated-transport profile; the rows and aux are ordinary signed
        // events and must survive the store's verification when the engine ingests
        // them in step 6.
        let ingestible = events.filter { $0.kind != .windowBounds && $0.kind != .threadSummary }
        let allValid = ingestible.allSatisfy(\.isValid)
        #expect(allValid)
    }
}
