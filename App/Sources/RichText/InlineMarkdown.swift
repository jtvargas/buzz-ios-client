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
    /// plain text, never as a link. See ``RichTextTarget/isAllowedAuthoredLink(_:)``
    /// — `hive-entity:` is deliberately *not* among them, so an authored link can
    /// never impersonate a resolved mention.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Parses `text`'s inline markdown, preserving whitespace, with unsafe links
    /// stripped and `<u>…</u>` folded into an underline. Falls back to the raw text
    /// when the content is not valid markdown.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        sanitizeLinks(&attributed)
        applyUnderlineTags(&attributed)
        return attributed
    }

    // MARK: - `<u>` tags

    /// Folds `<u>…</u>` into ``UnderlineAttribute`` and deletes the two tags.
    ///
    /// # Why the tags are found as runs rather than as text
    ///
    /// Foundation's parser already tells us where the inline HTML is: it marks `<u>`
    /// and `</u>` as runs carrying `InlinePresentationIntent.inlineHTML` and leaves
    /// their characters in place. Reading that is exact, where scanning the character
    /// view for the literal string is not — a message that merely *says* `<u>` inside
    /// a code span carries no such intent and is left alone for free.
    ///
    /// An unclosed `<u>` underlines to the end of the block, which is what upstream's
    /// `<u>(.*?)(?:</u>|$)` does. A stray `</u>` with nothing open is left as the
    /// literal text it is, because deleting it would remove characters the author can
    /// see without underlining anything.
    ///
    /// Only `<u>` is folded. Every other tag stays as written — upstream renders
    /// `<b>bold</b>` literally too, and silently swallowing tags this renderer does not
    /// implement would take text off the screen.
    private static func applyUnderlineTags(_ attributed: inout AttributedString) {
        let tags = underlineTags(in: attributed)
        guard !tags.isEmpty else { return }

        // Attributes first, deletions after: an attribute write preserves indices, so
        // every range collected above is still valid while the spans are marked.
        var open: Range<AttributedString.Index>?
        var doomed: [Range<AttributedString.Index>] = []
        for tag in tags {
            if tag.isOpen {
                if open == nil { open = tag.range }
            } else if let start = open {
                attributed[start.upperBound ..< tag.range.lowerBound].underline = true
                doomed.append(start)
                doomed.append(tag.range)
                open = nil
            }
        }
        if let start = open {
            attributed[start.upperBound ..< attributed.endIndex].underline = true
            doomed.append(start)
        }

        // Back to front: removing a range shifts everything after it, and nothing
        // before it.
        for range in doomed.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            attributed.removeSubrange(range)
        }
    }

    /// Every `<u>` and `</u>` in `attributed`, in order, as `(range, isOpen)`.
    private static func underlineTags(
        in attributed: AttributedString
    ) -> [(range: Range<AttributedString.Index>, isOpen: Bool)] {
        attributed.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.inlineHTML) == true else { return nil }
            switch String(attributed[run.range].characters).lowercased() {
            case "<u>": return (run.range, true)
            case "</u>": return (run.range, false)
            default: return nil
            }
        }
    }

    /// Strips the link attribute from any run whose URL is not an allowed scheme, so
    /// a tap can never open an arbitrary-scheme URL. The visible text is kept.
    private static func sanitizeLinks(_ attributed: inout AttributedString) {
        let disallowed = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return RichTextTarget.isAllowedAuthoredLink(url) ? nil : run.range
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
