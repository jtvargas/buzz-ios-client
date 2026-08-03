import Foundation

/// How well a typed query matches one named thing — the app's one answer to "which of
/// these did they mean?".
///
/// Extracted so the two surfaces that rank people against a query cannot drift apart:
/// composer autocomplete (`@` and `#`) and the new-direct-message picker. Both are
/// answering the same question about the same directory, and a person who ranks third in
/// one and seventh in the other is a bug nobody would think to look for.
///
/// # The strings are normalized once, not per keystroke
///
/// Case- and diacritic-folding a name is not free, and a roster is scanned in full on
/// every character typed. So the folded forms are computed when the roster changes and
/// held here; ``score(for:allowingSubstring:)`` does comparisons and nothing else. The
/// *query* is the caller's to normalize — through ``normalized(_:)``, once per keystroke
/// rather than once per candidate.
struct NameMatch: Sendable, Hashable {
    /// The normalized display name — what a query is really aimed at.
    let name: String
    /// A second string that matches at name priority: a person's NIP-05. Empty when
    /// there is none, which scores nothing rather than matching an empty query.
    let secondary: String
    /// `name` split into words, for matching inside a multi-word name.
    let words: [String]
    /// The raw identifier a query may be a pasted prefix of — a pubkey. Empty to opt out.
    let identifier: String

    init(name: String, secondary: String = "", identifier: String = "") {
        let folded = Self.normalized(name)
        self.name = folded
        self.secondary = Self.normalized(secondary)
        words = folded.split { $0.isWhitespace || $0 == "-" || $0 == "_" }.map(String.init)
        self.identifier = identifier.lowercased()
    }

    /// Lower is better; `nil` is no match at all.
    ///
    /// Exact name, then name prefix, then a whole interior word, then an interior word's
    /// prefix, then the raw identifier — and, only when asked, a bare substring last.
    ///
    /// An empty query matches everything at the top score, which is what lets a surface
    /// show its whole roster before anything is typed without a second code path.
    ///
    /// - Parameter allowingSubstring: whether a match anywhere inside the name counts.
    ///   Off by default: composer autocomplete has never offered `Jordan` for `dan`, and
    ///   turning that on for every `@` in the app is a change to a shipped surface rather
    ///   than a shared improvement. The picker asks for it because a roster is browsed as
    ///   well as typed at — the reader may only remember part of a name, and the tier
    ///   sits below every deliberate one so it can never outrank them.
    func score(for query: String, allowingSubstring: Bool = false) -> Int? {
        guard !query.isEmpty else { return 0 }
        if name == query || secondary == query { return 0 }
        if name.hasPrefix(query) || secondary.hasPrefix(query) { return 1 }
        if words.contains(query) { return 2 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 3 }
        if !identifier.isEmpty, identifier.hasPrefix(query) { return 4 }
        if allowingSubstring, name.contains(query) || secondary.contains(query) { return 5 }
        return nil
    }

    /// The one folding every candidate and every query passes through: case- and
    /// diacritic-insensitive, so `José` is reachable by typing `jose`.
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
