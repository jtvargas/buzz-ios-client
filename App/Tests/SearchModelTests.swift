import BuzzKit
@testable import Hive
import Testing

@MainActor
@Suite("Search model", .timeLimit(.minutes(1)))
struct SearchModelTests {
    @Test("same text is a no-op and submit bypasses an active debounce")
    func duplicateAndSubmit() async throws {
        let database = TempStore()
        defer { database.remove() }
        let store = try database.open()
        let probe = SearchLookupProbe()
        let model = SearchModel(store: store, selfPubkey: "reader", debounce: .seconds(60)) {
            try await probe.lookup($0)
        }

        model.search("  bees  ")
        model.search("bees")
        #expect(model.current == "bees")
        #expect(model.isSearching)
        #expect(await probe.queries.isEmpty)

        model.submit("bees")
        await probe.waitForQuery("bees")
        #expect(await probe.queries == ["bees"])
        await probe.resolve("bees", with: .empty)
        await Task.yield()
        #expect(model.hasSearched)
        #expect(!model.isSearching)
    }

    @Test("an abandoned lookup cannot overwrite the current answer")
    func staleAnswerIsDiscarded() async throws {
        let database = TempStore()
        defer { database.remove() }
        let store = try database.open()
        let probe = SearchLookupProbe()
        let model = SearchModel(store: store, selfPubkey: "reader", debounce: .zero) {
            try await probe.lookup($0)
        }

        model.search("old")
        await probe.waitForQuery("old")
        model.search("current")
        await probe.waitForQuery("current")

        let current = SearchSnapshot(results: .empty, directory: .empty, channels: [])
        await probe.resolve("current", with: current)
        await Task.yield()
        await probe.resolve("old", with: .empty)
        await Task.yield()

        #expect(model.current == "current")
        #expect(model.hasSearched)
        #expect(!model.isSearching)
    }

    @Test("queries shorter than two characters clear without looking up")
    func minimumLength() async throws {
        let database = TempStore()
        defer { database.remove() }
        let store = try database.open()
        let probe = SearchLookupProbe()
        let model = SearchModel(store: store, selfPubkey: "reader", debounce: .zero) {
            try await probe.lookup($0)
        }

        model.search("a")

        #expect(model.results == .empty)
        #expect(!model.isSearching)
        #expect(!model.hasSearched)
        #expect(await probe.queries.isEmpty)
    }
}

private actor SearchLookupProbe {
    private(set) var queries: [String] = []
    private var continuations: [String: CheckedContinuation<SearchSnapshot, Error>] = [:]

    func lookup(_ query: String) async throws -> SearchSnapshot {
        queries.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[query] = continuation
        }
    }

    func resolve(_ query: String, with snapshot: SearchSnapshot) {
        continuations.removeValue(forKey: query)?.resume(returning: snapshot)
    }

    func waitForQuery(_ query: String) async {
        while !queries.contains(query) { await Task.yield() }
    }
}
