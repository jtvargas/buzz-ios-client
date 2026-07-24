import Foundation

/// NIP-01 canonical serialization, used solely to derive an event id.
///
/// The id is the SHA-256 of the UTF-8 bytes of the array
///
///     [0, <pubkey>, <created_at>, <kind>, <tags>, <content>]
///
/// carrying no insignificant whitespace. This form is assembled by hand on
/// purpose: `JSONEncoder` must not be used for it. `JSONEncoder` escapes `/` as
/// `\/` and emits non-ASCII scalars as `\uXXXX`, and it gives no ordering or
/// spacing guarantees — each of those changes the byte sequence, and therefore
/// the hash, so an id computed with it would disagree with every other Nostr
/// implementation. Only the escapes NIP-01 mandates are applied here; every
/// other character, including `/` and all non-ASCII scalars, is emitted verbatim
/// as UTF-8.
enum CanonicalJSON {
    /// Builds the canonical byte sequence for the given event fields.
    static func serialize(
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String
    ) -> Data {
        var output = "[0,"
        output += escaped(pubkey)
        output += ","
        output += String(createdAt)
        output += ","
        output += String(kind.rawValue)
        output += ","
        output += serialize(tags: tags)
        output += ","
        output += escaped(content)
        output += "]"
        return Data(output.utf8)
    }

    private static func serialize(tags: [[String]]) -> String {
        var output = "["
        for (tagIndex, tag) in tags.enumerated() {
            if tagIndex > 0 { output += "," }
            output += "["
            for (elementIndex, element) in tag.enumerated() {
                if elementIndex > 0 { output += "," }
                output += escaped(element)
            }
            output += "]"
        }
        output += "]"
        return output
    }

    /// Wraps a string in quotes, applying exactly the escapes NIP-01 requires.
    ///
    /// Control characters below `0x20` without a dedicated short escape are
    /// emitted as `\u00xx`. Everything at or above `0x20` — including `/` and
    /// every multi-byte scalar — passes through unchanged.
    private static func escaped(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case let control where control.value < 0x20:
                output += String(format: "\\u%04x", control.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }
}
