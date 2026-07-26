import Foundation

/// The autolink stage: finds the links a message *contains* rather than the ones it
/// *marks up*, and attaches them as `link` runs.
///
/// Markdown only makes `[text](url)` a link, so a plain `https://…` or `name@host`
/// typed into a message arrived at the renderer as inert text. Everything a reader
/// would call a link now becomes one:
///
/// - web URLs and email addresses, via `NSDataDetector` (the same detector Mail and
///   Messages use, so what lights up here is what lights up there);
/// - Buzz's own `buzz://message?channel=…&id=…` links, which no detector knows —
///   they are what Desktop's *Copy link* puts on the clipboard, so they arrive as
///   bare text and would otherwise be the one link shape the workspace's own users
///   paste that this app ignored.
///
/// Runs that already carry a link are left alone (an authored `[label](url)` keeps
/// its label), and inline code is never scanned — `` `see https://x` `` is a code
/// span, not a link.
enum RichTextAutolink {
    /// The most matches attached per inline. Message content is untrusted and a
    /// pathological line of thousands of tiny URLs would otherwise cost a run each,
    /// on every render, forever. Well above anything a person writes.
    static let maxMatches = 64

    /// The detector, built once: `NSDataDetector` compiles its patterns on init, and
    /// a message list re-parses on every profile change.
    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Attaches links to every unmarked URL, email, and internal message link in
    /// `input`.
    static func apply(_ input: AttributedString) -> AttributedString {
        var output = input
        let plain = String(output.characters)
        guard !plain.isEmpty else { return output }

        // Read-only first, mutate after: attribute writes preserve indices, so every
        // range collected here stays valid while they are applied.
        let excluded = excludedRanges(output)
        var found: [(Range<String.Index>, URL)] = []

        detector?.enumerateMatches(
            in: plain,
            range: NSRange(plain.startIndex ..< plain.endIndex, in: plain)
        ) { match, _, stop in
            guard found.count < maxMatches else {
                stop.pointee = true
                return
            }
            guard let match, let url = match.url,
                  let range = Range(match.range, in: plain),
                  RichTextTarget.isAllowedAuthoredLink(url)
            else { return }
            found.append((range, url))
        }

        found.append(contentsOf: internalLinks(in: plain, limit: maxMatches - found.count))

        for (range, url) in found {
            guard let attributedRange = output.range(of: range, in: plain) else { continue }
            guard !excluded.contains(where: { $0.overlaps(attributedRange) }) else { continue }
            output[attributedRange].link = url
        }
        return output
    }

    // MARK: - Internal links

    /// Bare `buzz://message?…` runs, which `NSDataDetector` does not recognise.
    ///
    /// Scanned to the first whitespace and then trimmed of trailing sentence
    /// punctuation, so `see buzz://message?channel=a&id=b.` links the URL and not the
    /// full stop. A candidate is kept only if ``RichTextTarget`` can actually route
    /// it — a truncated one renders as plain text rather than as a dead link.
    private static func internalLinks(in plain: String, limit: Int) -> [(Range<String.Index>, URL)] {
        guard limit > 0 else { return [] }
        let prefix = "\(RichTextTarget.internalScheme)://message?"
        var results: [(Range<String.Index>, URL)] = []
        var searchStart = plain.startIndex

        while results.count < limit,
              let start = plain.range(
                  of: prefix,
                  options: [.caseInsensitive],
                  range: searchStart ..< plain.endIndex
              ) {
            var end = start.upperBound
            while end < plain.endIndex, !plain[end].isWhitespace { end = plain.index(after: end) }
            while end > start.upperBound, isTrailingPunctuation(plain[plain.index(before: end)]) {
                end = plain.index(before: end)
            }
            let candidate = String(plain[start.lowerBound ..< end])
            if let url = URL(string: candidate), RichTextTarget(url: url) != nil {
                results.append((start.lowerBound ..< end, url))
            }
            searchStart = end
        }
        return results
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        ".,;:!?)]}\"'".contains(character)
    }

    // MARK: - Exclusions

    /// Ranges the scan must not touch: inline code spans, and runs that already carry
    /// a link.
    private static func excludedRanges(_ attributed: AttributedString) -> [Range<AttributedString.Index>] {
        attributed.runs.compactMap { run in
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            return isCode || run.link != nil ? run.range : nil
        }
    }
}

private extension AttributedString {
    /// Maps a range of the plain-text projection back onto this string.
    ///
    /// `String(characters)` is character-for-character with the attributed string, so
    /// the two are related by a character offset — which is what makes a
    /// `String`-based detector usable against an `AttributedString` without a second
    /// parse.
    func range(of range: Range<String.Index>, in plain: String) -> Range<Index>? {
        let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let length = plain.distance(from: range.lowerBound, to: range.upperBound)
        let view = characters
        guard let lower = view.index(view.startIndex, offsetBy: start, limitedBy: view.endIndex),
              let upper = view.index(lower, offsetBy: length, limitedBy: view.endIndex)
        else { return nil }
        return lower ..< upper
    }
}
