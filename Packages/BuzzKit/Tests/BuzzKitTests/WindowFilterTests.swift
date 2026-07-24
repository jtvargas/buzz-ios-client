@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("WindowFilter request encoding")
struct WindowFilterTests {
    private let channel = "2f8a1c4e-6b3d-4a9f-8e21-0c5d7b9a1e34"

    /// Decodes the `POST /query` body — a JSON array of one filter object — back to
    /// a dictionary for field assertions.
    private func encodedObject(_ filter: WindowFilter) throws -> [String: Any] {
        let data = try filter.encodedRequestBody()
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(array.count == 1)
        return try #require(array.first)
    }

    @Test("A head request carries the extension keys and no cursor fields")
    func headRequestShape() throws {
        let object = try encodedObject(WindowFilter(channelID: channel))

        #expect(object["#h"] as? [String] == [channel])
        #expect(object["kinds"] as? [Int] == [EventKind.channelMessage.rawValue])
        #expect(object["limit"] as? Int == 50)
        // top_level MUST be the boolean true to select the window path.
        #expect(object["top_level"] as? Bool == true)
        #expect(object["include_summaries"] as? Bool == true)
        #expect(object["include_aux"] as? Bool == true)
        // Head = neither cursor field on the wire.
        #expect(object["until"] == nil)
        #expect(object["before_id"] == nil)
    }

    @Test("A cursored request carries both until and before_id, never one alone")
    func cursoredRequestShape() throws {
        let cursor = WindowCursor(createdAt: 1_751_499_000, id: String(repeating: "a", count: 64))
        let filter = WindowFilter(channelID: channel, cursor: .after(cursor))
        let object = try encodedObject(filter)

        #expect(object["until"] as? Int == 1_751_499_000)
        #expect(object["before_id"] as? String == cursor.id)
        // The composite cursor is all-or-nothing: the enum makes a half cursor
        // unrepresentable, so both keys are always present together.
        #expect(object["until"] != nil && object["before_id"] != nil)
    }

    @Test("An absent kinds restriction omits the key entirely")
    func omitsAbsentKinds() throws {
        let object = try encodedObject(WindowFilter(channelID: channel, kinds: nil))
        #expect(object["kinds"] == nil)
        #expect(object["#h"] as? [String] == [channel])
    }

    @Test("include flags and limit are carried through as given")
    func carriesFlagsAndLimit() throws {
        let filter = WindowFilter(
            channelID: channel, limit: 200, includeSummaries: false, includeAux: false
        )
        let object = try encodedObject(filter)
        #expect(object["limit"] as? Int == 200)
        #expect(object["include_summaries"] as? Bool == false)
        #expect(object["include_aux"] as? Bool == false)
    }

    @Test("baseFilter is the extension-stripped standard projection for the fallback")
    func baseFilterStripsExtensions() throws {
        let cursor = WindowCursor(createdAt: 1_751_499_000, id: String(repeating: "b", count: 64))
        let filter = WindowFilter(channelID: channel, cursor: .after(cursor))

        let base = filter.baseFilter
        #expect(base.kinds == [.channelMessage])
        #expect(base.tagQueries["h"] == [channel])
        #expect(base.limit == 50)
        // `until` is standard NIP-01 and survives; `before_id` is an extension and
        // is dropped — exactly the clean filter the §Degradation fallback reissues.
        #expect(base.until == 1_751_499_000)

        let standardJSON = try #require(String(bytes: base.canonicalJSON(), encoding: .utf8))
        #expect(!standardJSON.contains("top_level"))
        #expect(!standardJSON.contains("before_id"))
        #expect(!standardJSON.contains("include_"))
    }

    @Test("The expected bounds d-tag echoes head or the composite cursor")
    func expectedBoundsBinding() {
        #expect(WindowFilter(channelID: channel).expectedBoundsDTag == "\(channel):head")

        let cursor = WindowCursor(createdAt: 1_751_499_000, id: String(repeating: "c", count: 64))
        let cursored = WindowFilter(channelID: channel, cursor: .after(cursor))
        #expect(cursored.expectedBoundsDTag == "\(channel):1751499000:\(cursor.id)")
    }
}
