import Foundation

/// Turning a markdown file's bytes into the blocks the app already knows how to draw.
///
/// # Why this is the message pipeline with two stages removed
///
/// A message and a document are the same markdown, so they go through the same parser and the
/// same renderer — that is the whole point, and it is what makes a heading, a table, a fenced
/// block and a nested list look identical wherever the reader meets them. What a document does
/// *not* get is the two stages that are about a message being a message:
///
/// - **The entity pass.** `@name` and `#section` mean something in a channel and nothing in a
///   file. `[Overview](#overview)` — the anchor link every long README opens with — would
///   resolve `#overview` against the workspace's channel map and draw a pill that navigates
///   somewhere, which is a link the document's author never wrote.
/// - **The link-preview cards.** They are appended at the *end* of a message, which is the
///   right place for the two or three links a sentence points at and the wrong place for a
///   document whose links are its content: a README would grow a stack of cards under its
///   last paragraph naming four links from somewhere in the middle of it.
///
/// Autolinking stays, so a bare URL in a document is still pressable, and the media stage is
/// simply not applicable — it describes a message's `imeta` attachments, and a file has none.
enum MarkdownDocumentContent {
    /// The most text this renders.
    ///
    /// A parse is linear and a `Text` is not: the renderer builds one `AttributedString` per
    /// block and SwiftUI lays every one of them out, so a multi-megabyte file is not slow to
    /// read, it is slow to *draw*. 400k characters is far past any README and far short of the
    /// size where a phone stops being able to scroll the result.
    static let characterLimit = 400_000

    /// `text` as blocks, truncated at ``characterLimit`` with a rule and a line saying so.
    ///
    /// Truncation is visible on purpose. A document that silently stopped part-way is a
    /// document the reader believes they have read to the end of.
    static func message(for text: String) -> RichMessage {
        let (body, wasTruncated) = truncated(text)
        var blocks = RichTextParser.parse(body).mapInlines(RichTextAutolink.apply)
        if wasTruncated {
            blocks.append(.rule)
            blocks.append(.paragraph(AttributedString(
                "This file is too long to show in full. Open it in a browser to read the rest."
            )))
        }
        return RichMessage(blocks: blocks)
    }

    /// `text` cut to the limit, and whether it was cut.
    ///
    /// Cut at the last line break before the limit rather than mid-line, so the parser is never
    /// handed half a fence or half a table row — a truncation that lands inside one turns the
    /// tail of the document into a code block or a paragraph of pipes.
    private static func truncated(_ text: String) -> (String, Bool) {
        guard text.count > characterLimit else { return (text, false) }
        let cut = text.index(text.startIndex, offsetBy: characterLimit)
        let head = text[..<cut]
        guard let lastBreak = head.lastIndex(of: "\n") else { return (String(head), true) }
        return (String(head[..<lastBreak]), true)
    }
}
