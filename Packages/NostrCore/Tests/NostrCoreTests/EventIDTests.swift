import Foundation
@testable import NostrCore
import Testing

/// NIP-01 event-id vectors.
///
/// Expected ids were derived independently with a Python script that hashes the
/// exact canonical array with `hashlib.sha256` over `json.dumps(..., ensure_ascii
/// =False, separators=(",", ":"))` — the same byte sequence this codec assembles
/// by hand. Each vector's canonical string is reproduced in a comment so a
/// reviewer can re-derive the id without the script.
@Suite("Canonical serialization and event id")
struct EventIDTests {
    private func canonicalString(
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String
    ) throws -> String {
        let bytes = CanonicalJSON.serialize(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        return try #require(String(bytes: bytes, encoding: .utf8))
    }

    private func computedID(
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String
    ) -> String {
        NostrEvent.computeID(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        ).hexString
    }

    @Test("ASCII content")
    func asciiVector() throws {
        let pubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        let tags = [["t", "nostr"], ["client", "buzz"]]
        let content = "Hello, Nostr! Testing 123."

        // [0,"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
        //  1700000000,1,[["t","nostr"],["client","buzz"]],"Hello, Nostr! Testing 123."]
        let expectedCanonical =
            "[0,\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\","
                + "1700000000,1,[[\"t\",\"nostr\"],[\"client\",\"buzz\"]],\"Hello, Nostr! Testing 123.\"]"
        let expectedID = "1f93528869969956628ebbd2ec68cd56e7003bcf6723e648d405b3d95d7ccf33"

        #expect(try canonicalString(pubkey: pubkey, createdAt: 1_700_000_000, kind: 1, tags: tags,
                                    content: content) == expectedCanonical)
        #expect(computedID(pubkey: pubkey, createdAt: 1_700_000_000, kind: 1, tags: tags,
                           content: content) == expectedID)
    }

    @Test("Non-ASCII content is emitted verbatim as UTF-8, not \\uXXXX")
    func nonASCIIVector() throws {
        let pubkey = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
        let content = "こんにちは 🌍 café — 日本語 test"

        // [0,"82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2",
        //  1699999999,1,[],"こんにちは 🌍 café — 日本語 test"]
        let expectedCanonical =
            "[0,\"82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2\","
                + "1699999999,1,[],\"こんにちは 🌍 café — 日本語 test\"]"
        let expectedID = "d8e64bfadbb661761dbb7416e9c2935ec65243baadd4407cd17ec71ab94547f5"

        let canonical = try canonicalString(pubkey: pubkey, createdAt: 1_699_999_999, kind: 1, tags: [],
                                            content: content)
        #expect(canonical == expectedCanonical)
        #expect(canonical.contains("🌍"))
        #expect(!canonical.contains("\\u"))
        #expect(computedID(pubkey: pubkey, createdAt: 1_699_999_999, kind: 1, tags: [],
                           content: content) == expectedID)
    }

    @Test("Forward slashes are never escaped")
    func slashVector() throws {
        let pubkey = "1111111111111111111111111111111111111111111111111111111111111111"
        let tags = [["d", "read/state"], ["url", "https://example.com/a/b?x=1&y=2"]]
        let content = "path/to/resource — see https://example.com/x/y"

        // [0,"1111111111111111111111111111111111111111111111111111111111111111",
        //  1650000123,30078,[["d","read/state"],["url","https://example.com/a/b?x=1&y=2"]],
        //  "path/to/resource — see https://example.com/x/y"]
        let expectedCanonical =
            "[0,\"1111111111111111111111111111111111111111111111111111111111111111\","
                + "1650000123,30078,[[\"d\",\"read/state\"],"
                + "[\"url\",\"https://example.com/a/b?x=1&y=2\"]],"
                + "\"path/to/resource — see https://example.com/x/y\"]"
        let expectedID = "ce21d453cd05ddae7433574d1c184b354c13ff38bb23b91609ba0c0489723274"

        let canonical = try canonicalString(pubkey: pubkey, createdAt: 1_650_000_123, kind: 30078,
                                            tags: tags, content: content)
        #expect(canonical == expectedCanonical)
        #expect(!canonical.contains("\\/"))
        #expect(computedID(pubkey: pubkey, createdAt: 1_650_000_123, kind: 30078, tags: tags,
                           content: content) == expectedID)
    }

    @Test("Control characters use the mandated short escapes")
    func controlCharacterVector() throws {
        let pubkey = "2222222222222222222222222222222222222222222222222222222222222222"
        let tags = [["desc", "tab\tnl\nquote\"back\\slash"]]
        let content = "line1\nline2\ttabbed \"quoted\" \\ end"
        let expectedID = "2ccac22a25ca7fb9f44786fc9ab622682d8fcf12a4fea4fbede54d0edc018c2a"

        let canonical = try canonicalString(pubkey: pubkey, createdAt: 1_600_000_000, kind: 1,
                                            tags: tags, content: content)
        // Raw control bytes must not appear; their two-character escapes must.
        #expect(!canonical.unicodeScalars.contains { $0.value == 0x0A })
        #expect(!canonical.unicodeScalars.contains { $0.value == 0x09 })
        #expect(canonical.contains("\\n"))
        #expect(canonical.contains("\\t"))
        #expect(canonical.contains("\\\""))
        #expect(canonical.contains("\\\\"))
        #expect(computedID(pubkey: pubkey, createdAt: 1_600_000_000, kind: 1, tags: tags,
                           content: content) == expectedID)
    }
}
