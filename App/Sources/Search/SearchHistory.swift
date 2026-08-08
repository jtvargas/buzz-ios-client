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

/// The terms this reader has searched for in one community, newest first.
///
/// # Why per community
///
/// Because search *is* per community — one store is open at a time and a query never crosses
/// them — so a term carried over is an offer to run a search that cannot return what it
/// returned last time. It is also the wrong thing to show: the terms are the names of that
/// community's people, channels and work. The owner's rule, and the same shape the recently
/// visited places already follow.
///
/// # Why `UserDefaults` and not the store
///
/// Because it is not conversation data. The store is the event log and its projections: it is
/// wiped on an identity change, rebuilt on a `projectionVersion` bump, and every table in it
/// answers to something the relay said. A search term answers to nobody, survives neither
/// requirement, and would be one more thing to remember to delete in
/// ``BuzzEventStore/wipe()``. It is a handful of short strings — a defaults key is the honest
/// size of the problem.
@MainActor
@Observable
final class SearchHistory {
    /// How many terms are kept, per community. The owner's number.
    ///
    /// Enough that the list is genuinely a history rather than a peek at the last few, and
    /// small enough that the whole thing is one small write per search and one decode per
    /// community switch.
    static let limit = 40

    private(set) var terms: [RecentSearch] = []

    private let defaults: UserDefaults
    private let prefix: String
    /// The community whose terms are loaded. `nil` before one is active, which is a real state
    /// on a cold launch — and one that must not be given a bucket of its own, or the first
    /// search of a session lands somewhere the reader will never see it again.
    private var community: UUID?

    init(defaults: UserDefaults = .standard, prefix: String = "search.recentTerms") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// Loads the terms for a community, and files nothing until one is named.
    ///
    /// Idempotent: the view drives this from the active community, which re-reports the same
    /// id across every unrelated change.
    func activate(community id: UUID?) {
        guard community != id else { return }
        community = id
        terms = id.map { Self.decode(defaults.data(forKey: Self.key(prefix, $0))) } ?? []
    }

    /// Where this community's terms are written, or `nil` while there is no community — in
    /// which case nothing is recorded rather than recorded somewhere unreachable.
    private var key: String? {
        community.map { Self.key(prefix, $0) }
    }

    /// The defaults key one community's terms live under. `uuidString` rather than the
    /// interpolated description, so the key cannot change if `Community.ID` ever stops being
    /// a `UUID` without this failing to compile first.
    private static func key(_ prefix: String, _ id: UUID) -> String {
        "\(prefix).\(id.uuidString)"
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
        guard !trimmed.isEmpty, community != nil else { return }
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
        guard let key else { return }
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
