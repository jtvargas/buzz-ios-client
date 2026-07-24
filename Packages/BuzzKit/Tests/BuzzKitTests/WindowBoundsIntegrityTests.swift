@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// T7 (spec step 5): the bounds-integrity MUST list. Every malformed `kind:39006`
/// variant discards the page (the engine leaves the watermark untouched); the
/// no-bounds variant additionally signals the degradation fallback.
@Suite("Window bounds integrity (T7)")
struct WindowBoundsIntegrityTests {
    /// Fetches a head window whose response is `events`, for the builder's channel.
    private func fetchHead(
        _ build: WindowResponseBuilder, _ events: [NostrEvent]
    ) async throws -> WindowResult {
        let (result, _) = try await WindowClient.fetch(
            WindowFilter(channelID: build.channel),
            respondingWith: try WindowResponseBuilder.body(events),
            signer: try InMemorySigner()
        )
        return result
    }

    // MARK: - The four T7 variants

    @Test("Missing 39006 → degradation fallback (no valid bounds)")
    func missingBounds() async throws {
        let build = try WindowResponseBuilder()
        let row = try build.row("orphan", at: 1_700_000_300)

        // No bounds overlay at all: the capability-absent signal. Discarded *and*
        // the degradation trigger the engine falls back on.
        let result = try await fetchHead(build, [row])
        #expect(result == .degraded(.noBoundsOverlay))
        #expect(isDegraded(result))
    }

    @Test("Duplicated 39006 → invalid page, fast path retained")
    func duplicatedBounds() async throws {
        let build = try WindowResponseBuilder()
        let row = try build.row("dup", at: 1_700_000_300)
        let first = try build.headBounds(hasMore: false)
        let second = try build.headBounds(hasMore: false, nextCursor: nil)

        let result = try await fetchHead(build, [row, first, second])
        #expect(result == .invalidPage(.multipleBounds(count: 2)))
        #expect(!isDegraded(result))
    }

    @Test("Wrong d-tag binding → invalid page")
    func wrongCursorBinding() async throws {
        let build = try WindowResponseBuilder()
        let row = try build.row("mis-bound", at: 1_700_000_300)
        // A well-formed cursor suffix, but we asked for head — the overlay answers a
        // different request and must not be trusted for this page.
        let strayCursor = "1700000200:\(String(repeating: "a", count: 64))"
        let bounds = try build.bounds(
            dSuffix: strayCursor,
            content: WindowResponseBuilder.boundsContent(hasMore: false, nextCursor: nil)
        )

        let result = try await fetchHead(build, [row, bounds])
        guard case let .invalidPage(.cursorBindingMismatch(expected, actual)) = result else {
            Issue.record("expected cursorBindingMismatch, got \(result)")
            return
        }
        #expect(expected == "\(build.channel):head")
        #expect(actual == "\(build.channel):\(strayCursor)")
    }

    @Test("has_more true with a null cursor → invalid page")
    func exhaustionInconsistentMoreButNull() async throws {
        let build = try WindowResponseBuilder()
        let row = try build.row("inconsistent", at: 1_700_000_300)
        // Violates has_more ⇔ next_cursor ≠ null.
        let bounds = try build.bounds(dSuffix: "head", content: "{\"has_more\":true,\"next_cursor\":null}")

        let result = try await fetchHead(build, [row, bounds])
        #expect(result == .invalidPage(.exhaustionInconsistent))
    }

    // MARK: - Additional content hardening

    @Test("has_more false with a present cursor → invalid page")
    func exhaustionInconsistentDoneButCursor() async throws {
        let build = try WindowResponseBuilder()
        let cursor = WindowCursor(createdAt: 1_700_000_050, id: String(repeating: "b", count: 64))
        let bounds = try build.bounds(
            dSuffix: "head",
            content: WindowResponseBuilder.boundsContent(hasMore: false, nextCursor: cursor)
        )

        let result = try await fetchHead(build, [bounds])
        #expect(result == .invalidPage(.exhaustionInconsistent))
    }

    @Test("Non-JSON bounds content → invalid page")
    func unparseableContent() async throws {
        let build = try WindowResponseBuilder()
        let bounds = try build.bounds(dSuffix: "head", content: "definitely not json")

        let result = try await fetchHead(build, [bounds])
        #expect(result == .invalidPage(.unparseableBoundsContent))
    }

    @Test("Wrong runtime types in bounds content → invalid page")
    func wrongRuntimeTypes() async throws {
        let build = try WindowResponseBuilder()
        // has_more as a string fails the typed decode — the step-5 field-type
        // hardening, obtained for free from Decodable.
        let bounds = try build.bounds(dSuffix: "head", content: "{\"has_more\":\"yes\",\"next_cursor\":null}")

        let result = try await fetchHead(build, [bounds])
        #expect(result == .invalidPage(.unparseableBoundsContent))
    }

    @Test("A next cursor whose id is not a 64-hex event id → invalid page")
    func nonCanonicalCursorID() async throws {
        let build = try WindowResponseBuilder()
        let bounds = try build.bounds(
            dSuffix: "head",
            content: "{\"has_more\":true,\"next_cursor\":{\"created_at\":1700000050,\"id\":\"short\"}}"
        )

        let result = try await fetchHead(build, [bounds])
        #expect(result == .invalidPage(.unparseableBoundsContent))
    }

    private func isDegraded(_ result: WindowResult) -> Bool {
        if case .degraded = result { return true }
        return false
    }
}
