import Foundation

/// Lightweight fuzzy matching for the channel browser's search field.
///
/// A port of Desktop's `channelSearchScore.ts`, band for band, so the two clients rank
/// the same query the same way: cheap, dependency-free, separator-aware scoring — no
/// Levenshtein / typo-tolerance, which reorders results unpredictably and hides the
/// channel a user can plainly see.
///
/// The one thing plain substring search gets wrong is contiguity across separators:
/// typing `releasenotes` or `reln` should still find `release-notes`. Two extra passes
/// fix that on top of substring:
///
///  1. word-boundary tokens (split on space/`-`/`_`), so multi-word names match when the
///     separators are dropped or a later word is typed, and
///  2. an in-order subsequence check, so `reln` matches `release-notes`.
///
/// Lower score = better match. `nil` means "no match".
enum ChannelSearchScore {
    // Score bands. Named steps so the intent (and ordering) is legible.
    private static let exact = 0
    private static let prefix = 1
    private static let wordExact = 2
    private static let wordPrefix = 3
    private static let substring = 4
    private static let collapsedSeparators = 5
    private static let subsequence = 6
    private static let description = 7

    /// Separators that delimit words in a channel name/description.
    private static let wordSeparators = CharacterSet(charactersIn: " \t\n-_./")

    /// Strip separators so `release-notes` and `releasenotes` compare equal.
    private static func collapseSeparators(_ value: String) -> String {
        String(value.unicodeScalars.filter { !wordSeparators.contains($0) })
    }

    /// Whether every character of `query` appears in `text` in order (not necessarily
    /// contiguously) — `reln` is a subsequence of `release-notes`.
    private static func isSubsequence(_ query: String, of text: String) -> Bool {
        guard !query.isEmpty else { return true }
        var remaining = query[...]
        for character in text {
            if character == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return true }
            }
        }
        return false
    }

    /// Score how well `name` matches `lowerQuery`, best (lowest) band first, or `nil`
    /// for no match. `lowerQuery` must already be lowercased and trimmed.
    static func scoreName(_ name: String, against lowerQuery: String) -> Int? {
        guard !lowerQuery.isEmpty else { return exact }

        let lower = name.lowercased()

        if lower == lowerQuery { return exact }
        if lower.hasPrefix(lowerQuery) { return prefix }

        let words = lower.components(separatedBy: wordSeparators).filter { !$0.isEmpty }
        if words.contains(lowerQuery) { return wordExact }
        if words.contains(where: { $0.hasPrefix(lowerQuery) }) { return wordPrefix }

        if lower.contains(lowerQuery) { return substring }

        // `releasenotes` → matches `release-notes` once separators are removed.
        let collapsedName = collapseSeparators(lower)
        let collapsedQuery = collapseSeparators(lowerQuery)
        if !collapsedQuery.isEmpty, collapsedName.contains(collapsedQuery) {
            return collapsedSeparators
        }

        // `reln` → matches `release-notes` as an in-order subsequence. At least 2 chars,
        // so a 1-char query does not turn every name containing that letter into noise.
        if collapsedQuery.count >= 2, isSubsequence(collapsedQuery, of: lower) {
            return subsequence
        }

        return nil
    }

    /// Score a channel against a query over both its name and its description.
    /// A description match always ranks below any name match — it is supplementary
    /// context, and a fuzzy description hit must not crowd out a name the reader typed.
    static func score(name: String, about: String?, against lowerQuery: String) -> Int? {
        guard !lowerQuery.isEmpty else { return exact }

        if let nameScore = scoreName(name, against: lowerQuery) { return nameScore }

        if let about, about.lowercased().contains(lowerQuery) {
            return description
        }

        return nil
    }
}
