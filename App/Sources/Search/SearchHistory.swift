import Foundation
import Observation

/// One term this reader has searched for, and when.
struct RecentSearch: Codable, Hashable, Identifiable {
    let term: String
    let searchedAt: Date

    /// The term itself. A term appears at most once — searching it again moves it to the top
    /// rather than adding a second row — so it is a stable identity for a list that reorders.
    var id: String { term }
}

/// The terms this reader has searched for, newest first.
///
/// # Why `UserDefaults` and not the store
///
/// Because it is not conversation data. The store is the event log and its projections: it is
/// wiped on an identity change, rebuilt on a `projectionVersion` bump, and every table in it
/// answers to something the relay said. A search term answers to nobody, survives neither
/// requirement, and would be one more thing to remember to delete in
/// ``BuzzEventStore/wipe()``. It is a handful of short strings — a defaults key is the honest
/// size of the problem.
///
/// It is *not* shared across identities on purpose either: the key is the whole app's, and a
/// term is not a secret about a conversation. If that ever changes, this is the one place to
/// change it.
@MainActor
@Observable
final class SearchHistory {
    /// How many terms are kept. The owner's number.
    ///
    /// Enough that the list is genuinely a history rather than a peek at the last few, and
    /// small enough that the whole thing is one small write per search and one decode per
    /// launch.
    static let limit = 40

    private(set) var terms: [RecentSearch] = []

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "search.recentTerms") {
        self.defaults = defaults
        self.key = key
        terms = Self.decode(defaults.data(forKey: key))
    }

    /// Files a term the reader actually searched for.
    ///
    /// Trimmed, and empty is not a search. Case is *preserved* but compared insensitively:
    /// "Bumble" and "bumble" are one entry, and the one kept is the way they last typed it,
    /// because that is the spelling they will recognise.
    ///
    /// Re-searching moves a term to the top rather than adding a row. A history that grew a
    /// duplicate every time would spend all forty slots on whatever the reader looks up most.
    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = terms.filter { $0.term.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(RecentSearch(term: trimmed, searchedAt: .now), at: 0)
        terms = Array(updated.prefix(Self.limit))
        persist()
    }

    /// Drops one term — the row's own swipe, for a search the reader would rather not see
    /// again.
    func remove(_ term: String) {
        terms.removeAll { $0.term == term }
        persist()
    }

    /// Drops the lot. What `Clear` does.
    func clear() {
        terms = []
        persist()
    }

    private func persist() {
        // A failure here loses the history and nothing else, and there is nothing useful to
        // tell the reader about it — the list on screen is already correct.
        defaults.set(try? JSONEncoder().encode(terms), forKey: key)
    }

    /// Decodes what was stored, or nothing.
    ///
    /// Truncated to the limit on the way in as well as on the way out, so lowering the limit
    /// takes effect on the next launch rather than waiting for enough searches to push the
    /// tail off.
    private static func decode(_ data: Data?) -> [RecentSearch] {
        guard let data, let stored = try? JSONDecoder().decode([RecentSearch].self, from: data) else {
            return []
        }
        return Array(stored.prefix(limit))
    }
}
