import Foundation

/// One person the new-direct-message sheet can offer, already resolved.
///
/// A plain value, not a directory reference: everything the sheet draws or matches on is
/// here, so the sheet needs no ``EntityNames``, no store, and no engine. That is what lets
/// the filtering be unit-tested with no relay and the sheet itself have a real preview —
/// and it keeps the one place that knows how an identity is *named* (``EntityNames``) at
/// the call site, where it already lives.
struct DirectMessagePerson: Identifiable, Hashable, Sendable {
    /// Lowercased hex — the identity handed to the relay, and this row's identity.
    let pubkey: String
    /// What to call them. Never a hex key: ``EntityNames/name(for:)`` has already fallen
    /// back to a shortened npub if it had to.
    let name: String
    /// The quiet second line: a NIP-05, or "Agent". `nil` for a person with neither.
    let secondary: String?
    let picture: URL?
    let initials: String
    let isAgent: Bool
    /// Whether ``name`` is a name somebody chose, rather than a shortened identifier.
    ///
    /// Carried rather than derived, because only the caller can tell the two apart —
    /// ``EntityNames/humanName(for:)`` returns `nil` for the second and ``name(for:)``
    /// makes both into a `String`. The list sorts the unnamed last: they are identities
    /// the directory has seen but nobody can recognise, and putting them above people
    /// with names buries the readable rows.
    let isNamed: Bool

    var id: String { pubkey }

    init(
        pubkey: String,
        name: String,
        secondary: String? = nil,
        picture: URL? = nil,
        initials: String = "?",
        isAgent: Bool = false,
        isNamed: Bool = true
    ) {
        self.pubkey = pubkey.lowercased()
        self.name = name
        self.secondary = secondary
        self.picture = picture
        self.initials = initials
        self.isAgent = isAgent
        self.isNamed = isNamed
    }
}

/// The new-direct-message sheet's state and every rule it applies: who is offered, in
/// what order, what a typed query does to that order, and how many people may be picked.
///
/// A value type holding no view, so the ranking is tested against the ranking rather than
/// through a layout. The sheet holds one in `@State` and mutates it; nothing here knows a
/// sheet exists.
///
/// # Why the whole roster is scanned on every keystroke
///
/// Because it is free. The people are already in memory — ``DirectorySnapshot/entities``
/// is a live dictionary the app maintains for naming — so there is no query to issue and
/// nothing to debounce. What is *not* free is folding case and diacritics off every name
/// per character typed, so that happens once in ``init`` (see ``NameMatch``) and a
/// keystroke costs a comparison per person. A workspace roster is hundreds of people, not
/// millions; scanning it is microseconds and needs no index beyond this one.
struct DirectMessagePicker: Equatable {
    /// Everyone offered, in the order they appear before anything is typed.
    let people: [DirectMessagePerson]
    /// The most people one direct message may be opened with, minus yourself.
    ///
    /// Injected rather than a constant here: the number is the *relay's*, and the picker
    /// is not the place that gets to know it. See the call site.
    let maxSelection: Int

    /// What has been typed. Setting it re-filters; there is nothing to await.
    var query: String = ""

    /// Who has been picked, in the order they were picked — which is the order the chips
    /// read in, and the only order the reader has any expectation about.
    private(set) var selection: [String] = []

    /// The folded strings, parallel to ``people``, built once.
    private let matches: [NameMatch]

    init(people: [DirectMessagePerson], maxSelection: Int) {
        let sorted = people.sorted(by: Self.precedes)
        self.people = sorted
        self.maxSelection = maxSelection
        matches = sorted.map {
            NameMatch(name: $0.name, secondary: $0.secondary ?? "", identifier: $0.pubkey)
        }
    }

    /// The most people the relay will open one direct message with, **not counting you**.
    ///
    /// Three independent sources agree on eight: `buzz dms open --help` documents its
    /// `--pubkey` as `1-8`, ``BuzzKit/SyncEngine``'s `signOpenCommand` explains that tagging
    /// yourself "would only spend one of the eight allowed slots", and ``ConversationMark``
    /// records that a DM caps at nine people because kind 41010 takes eight `p` tags and the
    /// relay merges the author in.
    ///
    /// Spelled here and handed to ``maxSelection`` at the call site rather than read from
    /// inside the picker, so the sheet stays indifferent to the number — and so there is one
    /// line to change rather than a search: it becomes BuzzKit's own constant once
    /// `openDirectMessage(with peers:)` declares one.
    static let relayPeerLimit = 8

    // MARK: - Results

    /// The rows to draw: everyone when nothing is typed, best matches first otherwise.
    var results: [DirectMessagePerson] {
        let query = NameMatch.normalized(query.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return people }
        return zip(people.indices, people)
            .compactMap { index, person in
                // The substring tier is on here and off in the composer: this is a list
                // being browsed, and a reader who remembers half a name should find it.
                matches[index].score(for: query, allowingSubstring: true).map { (person, $0) }
            }
            // Score first, then the resting order — so equal matches keep the ordering the
            // reader was already looking at rather than reshuffling per keystroke.
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : Self.precedes(lhs.0, rhs.0)
            }
            .map(\.0)
    }

    /// The picked people, in pick order, for the chips row.
    ///
    /// Resolved through ``people`` rather than stored as values, so a chip and its row can
    /// never show two different names for one person.
    var chips: [DirectMessagePerson] {
        let byKey = Dictionary(people.map { ($0.pubkey, $0) }, uniquingKeysWith: { first, _ in first })
        return selection.compactMap { byKey[$0] }
    }

    func isSelected(_ pubkey: String) -> Bool { selection.contains(pubkey.lowercased()) }

    /// Whether the cap is reached — the point at which unpicked rows stop responding.
    var isFull: Bool { selection.count >= maxSelection }

    /// Whether a row may still be picked: already-picked rows stay live so they can be
    /// *un*picked at the cap, which is the only way back from it.
    func canSelect(_ pubkey: String) -> Bool { isSelected(pubkey) || !isFull }

    var canStart: Bool { !selection.isEmpty }

    // MARK: - Selection

    /// Picks or unpicks one person. Refuses silently at the cap — the row that would be
    /// refused is drawn disabled, so there is no press to explain.
    mutating func toggle(_ pubkey: String) {
        let key = pubkey.lowercased()
        if let existing = selection.firstIndex(of: key) {
            selection.remove(at: existing)
        } else if !isFull {
            selection.append(key)
        }
    }

    mutating func deselect(_ pubkey: String) {
        selection.removeAll { $0 == pubkey.lowercased() }
    }

    // MARK: - Ordering

    /// The resting order: people before agents, named before merely identified, then by
    /// name, then by key.
    ///
    /// The key is the last tiebreak for the same reason ``EntityNames/groupTitle`` uses
    /// one — the roster arrives as a `Set`, so without a total order the same list would
    /// come out differently on each pass and rows would swap places under the finger.
    static func precedes(_ lhs: DirectMessagePerson, _ rhs: DirectMessagePerson) -> Bool {
        if lhs.isAgent != rhs.isAgent { return !lhs.isAgent }
        if lhs.isNamed != rhs.isNamed { return lhs.isNamed }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.pubkey < rhs.pubkey
    }
}
