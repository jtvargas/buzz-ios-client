import Foundation

/// The emphasis + link stage: parses one block's inline markdown (bold, italic,
/// strikethrough, code spans, links) into an `AttributedString`, preserving soft
/// line breaks and stripping unsafe link schemes.
///
/// # Hardening
///
/// Message content is untrusted — whatever a peer (or an agent) put on the wire —
/// so the parse is defensive:
///
/// - Inline markdown that fails to parse falls back to the raw text rather than
///   throwing (`AttributedString(markdown:)` is wrapped in `try?`), so a malformed
///   span never blanks a message.
/// - Links are sanitised: only `http`, `https`, and `mailto` survive as tappable
///   links. A `javascript:` or other-scheme link keeps its visible text but loses
///   the link attribute, so a tap can never hand an arbitrary URL to `openURL`.
///
/// Ported verbatim from the Phase-3 `MessageContent.inline`/`sanitizeLinks` path,
/// which this engine generalises and replaces.
enum InlineMarkdown {
    /// The link schemes a message may make tappable. Everything else renders as
    /// plain text, never as a link.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Parses `text`'s inline markdown, preserving whitespace, with unsafe links
    /// stripped. Falls back to the raw text when the content is not valid markdown.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        sanitizeLinks(&attributed)
        return attributed
    }

    /// Strips the link attribute from any run whose URL is not an allowed scheme, so
    /// a tap can never open an arbitrary-scheme URL. The visible text is kept.
    private static func sanitizeLinks(_ attributed: inout AttributedString) {
        let disallowed = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            guard let scheme = url.scheme?.lowercased(), allowedLinkSchemes.contains(scheme) else {
                return run.range
            }
            return nil
        }
        for range in disallowed {
            attributed[range].link = nil
        }
    }
}

/// Name normalisation shared by the resolver and the `#channel` map, so a lookup
/// keyed at build time matches a candidate scanned at render time: l-cased,
/// whitespace-collapsed (including non-breaking spaces), and trimmed.
enum RichTextName {
    static func normalized(_ raw: String) -> String {
        raw
            .split(whereSeparator: { $0 == "\u{00A0}" || $0.isWhitespace })
            .map { $0.lowercased() }
            .joined(separator: " ")
    }
}
