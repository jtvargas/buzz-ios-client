import Foundation
@testable import NostrCore
import Testing

@Suite("Filter encoding and NIP-01/NIP-50 fields")
struct FilterTests {
    /// Decodes a filter's canonical JSON into a dictionary for field-level
    /// assertions without depending on key order.
    private func fields(_ filter: Filter) throws -> [String: Any] {
        let data = try filter.canonicalJSON()
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("Encodes only the fields that are set")
    func omitsNilFields() throws {
        let filter = Filter(kinds: [.channelMessage], limit: 50)
        let encoded = try fields(filter)

        #expect(encoded.keys.sorted() == ["kinds", "limit"])
        #expect(encoded["ids"] == nil)
        #expect(encoded["authors"] == nil)
        #expect(encoded["since"] == nil)
        #expect(encoded["until"] == nil)
        #expect(encoded["search"] == nil)
    }

    @Test("An empty filter encodes to an empty object")
    func emptyFilter() throws {
        let string = try #require(String(bytes: Filter().canonicalJSON(), encoding: .utf8))
        #expect(string == "{}")
    }

    @Test("Every scalar field round-trips")
    func scalarRoundTrip() throws {
        let filter = Filter(
            ids: ["aa", "bb"],
            authors: ["cc"],
            kinds: [.textNote, .channelMessage],
            since: 1_700_000_000,
            until: 1_700_000_900,
            limit: 200,
            search: "hello world"
        )
        let data = try filter.canonicalJSON()
        let decoded = try JSONDecoder().decode(Filter.self, from: data)
        #expect(decoded == filter)
    }

    @Test("Tag queries encode as #-prefixed dynamic keys")
    func tagQueryDynamicKeys() throws {
        let filter = Filter(kinds: [.channelMessage])
            .inGroup("group-1")
            .taggingPubkey("abcd")
            .referencingEvent("ffff")
            .withTagQuery("t", ["buzz", "nostr"])

        let encoded = try fields(filter)
        #expect(encoded["#h"] as? [String] == ["group-1"])
        #expect(encoded["#p"] as? [String] == ["abcd"])
        #expect(encoded["#e"] as? [String] == ["ffff"])
        #expect(encoded["#t"] as? [String] == ["buzz", "nostr"])
        // The tag letter is never leaked without its `#`.
        #expect(encoded["h"] == nil)
    }

    @Test("Tag queries survive a decode round-trip keyed without the #")
    func tagQueryRoundTrip() throws {
        let filter = Filter(kinds: [.giftWrap]).taggingPubkey("deadbeef")
        let data = try filter.canonicalJSON()
        let decoded = try JSONDecoder().decode(Filter.self, from: data)
        #expect(decoded.tagQueries["p"] == ["deadbeef"])
        #expect(decoded == filter)
    }

    @Test("The NIP-50 search field encodes verbatim")
    func nip50Search() throws {
        let filter = Filter(search: "café ☕")
        let encoded = try fields(filter)
        #expect(encoded["search"] as? String == "café ☕")
    }

    @Test("Canonical encoding is byte-stable across encodes")
    func canonicalIsStable() throws {
        let filter = Filter(kinds: [.channelMessage])
            .withTagQuery("t", ["a"])
            .withTagQuery("g", ["b"])
            .taggingPubkey("cc")
        let first = try filter.canonicalJSON()
        let second = try filter.canonicalJSON()
        #expect(first == second)
    }

    @Test("A p-gated kind without a #p scope is flagged before sending")
    func needsPubkeyScope() {
        let unscoped = Filter(kinds: [.giftWrap])
        #expect(unscoped.needsPubkeyScope)

        let scoped = Filter(kinds: [.giftWrap]).taggingPubkey("abcd")
        #expect(!scoped.needsPubkeyScope)

        let ungated = Filter(kinds: [.channelMessage])
        #expect(!ungated.needsPubkeyScope)

        let kindless = Filter(limit: 10)
        #expect(!kindless.needsPubkeyScope)
    }

    @Test("Unknown kinds in a filter survive encode and decode")
    func unknownKindsSurvive() throws {
        let filter = Filter(kinds: [EventKind(rawValue: 987_654)])
        let data = try filter.canonicalJSON()
        let string = try #require(String(bytes: data, encoding: .utf8))
        #expect(string.contains("987654"))

        let decoded = try JSONDecoder().decode(Filter.self, from: data)
        #expect(decoded.kinds == [EventKind(rawValue: 987_654)])
    }
}
