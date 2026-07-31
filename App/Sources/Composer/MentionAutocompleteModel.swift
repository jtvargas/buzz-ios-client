import BuzzKit
import Foundation
import GRDB
import Observation

/// Live, locally indexed mention candidates for one channel: the people this author
/// may mention, and the channels they may reference.
///
/// Both kinds are indexed the same way and ranked by the same function; the trigger
/// the author typed picks which index is searched. That is deliberate — a `#` token
/// can never match a person and an `@` token can never match a channel, so the two
/// indexes never compete, and there is still only one scoring rule to reason about.
@MainActor
@Observable
final class MentionAutocompleteModel {
    private(set) var suggestions: [MentionSuggestion] = []
    /// Where an insertion lands. Not observable: no view reads it, and publishing it
    /// only invalidated readers of the object for a value they never look at.
    @ObservationIgnored private var activeRange: NSRange?
    /// The caret, in UTF-16 units — the anchor everything the panel shows is derived
    /// from. Not observable for the same reason ``activeRange`` is not: it moves on
    /// every keystroke and no view reads it.
    @ObservationIgnored private var cursor = 0
    var isComposerFocused = false

    private let channel: String
    private let store: BuzzEventStore
    private let selfPubkey: String?
    private var userIndex: [IndexedSuggestion] = []
    private var channelIndex: [IndexedSuggestion] = []
    private var document = MentionDraft()

    init(channel: String, store: BuzzEventStore, selfPubkey: String?) {
        self.channel = channel
        self.store = store
        self.selfPubkey = selfPubkey
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                // Both reads are `nonisolated` and run on the concurrent reader, and
                // both are re-read from one signal: a channel is projected from an
                // `event` row, so a rename or a new channel re-fires the same
                // observation the roster does.
                let candidates = (try? store.mentionCandidates(
                    channel: channel,
                    selfPubkey: selfPubkey
                )) ?? []
                let channels = (try? store.channelSuggestions()) ?? []
                // Who this author has `@`-named lately, read from the same signal as the
                // candidates themselves so the ranking and the list it ranks are always
                // the same snapshot.
                let recent = (try? store.recentMentions(
                    by: selfPubkey,
                    limit: Self.recencyDepth
                )) ?? .empty
                // Indexed here, off the main actor. Normalizing every row costs a few
                // milliseconds per hundred, and this loop re-fires on *every* committed
                // transaction — an arriving message, a reaction, a read-state blob — so
                // doing it on the way in would spend most of a frame on the main actor
                // each time. `IndexedSuggestion` is `Sendable`, so the built indexes
                // cross the hop instead of the raw rows.
                //
                // The recency rank is resolved here too, for the same reason the
                // normalized strings are: it is fixed for as long as the index lives, so
                // paying for the lookup once per snapshot beats paying for it per
                // candidate per keystroke.
                let users = candidates.enumerated().map {
                    IndexedSuggestion(.user($1), originalOrder: $0, recent: recent)
                }
                let references = channels.enumerated().map {
                    IndexedSuggestion(.channel($1), originalOrder: $0, recent: recent)
                }
                await apply(users: users, channels: references)
            }
        } catch {
            // Cancellation/teardown leaves the latest candidate snapshot visible.
        }
    }

    func update(for document: MentionDraft) {
        self.document = document
        // The edit that produced this draft knows exactly where it left the caret. A
        // draft nobody has edited — a fresh one, or one restored after a failed send —
        // is presented with the caret at its end, which is where ``TokenTextView`` puts
        // it on the first render.
        cursor = document.preferredCursor ?? (document.text as NSString).length
        refresh()
    }

    /// The caret moved without the text changing: a tap somewhere else in the draft, an
    /// arrow key, a selection. Without this the panel stayed open over a query that was
    /// no longer under the caret, and completion still filtered on the last word typed
    /// rather than on the word being edited.
    func updateSelection(_ selection: NSRange) {
        // A range selection has no single insertion point, so there is nothing to
        // complete — `@ad` with two of its characters selected is not a query anyone is
        // still typing.
        guard selection.length == 0 else {
            dismiss()
            return
        }
        // Recomputed even when the caret has not moved, deliberately. Skipping that made
        // a dismissal sticky: selecting a range and then putting the caret back where it
        // was left the panel closed for good, because the caret matched and the selection
        // that closed it had not moved anything. `refresh` already declines to write when
        // the result is unchanged, which is the cheap guard that actually holds.
        cursor = min(max(selection.location, 0), (document.text as NSString).length)
        refresh()
    }

    func select(_ suggestion: MentionSuggestion, in document: inout MentionDraft) {
        guard let activeRange else { return }
        document.insert(suggestion, replacing: activeRange)
        update(for: document)
    }

    /// Puts `kind`'s trigger in the draft at the caret and opens the panel on it — what the
    /// composer's `@` and `#` quick actions do.
    ///
    /// It lives here rather than in the view because the caret does: this model is what
    /// ``TokenTextView`` reports selection changes to, and an insertion aimed anywhere else
    /// would land at the end of the draft instead of where the author is writing.
    ///
    /// # The two rules
    ///
    /// **A trigger only opens a token when a word starts there.** ``MentionDraft`` refuses
    /// a trigger whose preceding character is not whitespace, which is what keeps `mail@test`
    /// and `C#` out of the panel — so a caret resting against a word gets a space first, or
    /// the button would insert a character and nothing would happen. Same rule, same reason,
    /// as the mobile client's `_insertTriggerAtCursor`.
    ///
    /// **A caret already inside a token of this kind gets nothing.** The panel is already
    /// open on the query being typed; a second trigger would push a bare one in beside it and
    /// close the panel the button exists to open. Pressing `#` inside an `@` token is a real
    /// change of mind, though, so only the matching kind is refused.
    ///
    /// Focus is taken either way: the button is reachable while the keyboard is down (the bar
    /// is on screen whether or not the field has the responder), and an author who presses it
    /// then means to start writing.
    func insertTrigger(_ kind: MentionKind, into document: inout MentionDraft) {
        isComposerFocused = true
        let text = document.text as NSString
        let caret = min(max(cursor, 0), text.length)
        guard document.activeMention(at: caret)?.kind != kind else { return }
        let opensAWord = caret == 0 || Self.isWhitespace(text.character(at: caret - 1))
        document.replaceCharacters(
            in: NSRange(location: caret, length: 0),
            with: opensAWord ? String(kind.trigger) : " \(kind.trigger)"
        )
        // The view's own `onChange` would do this a moment later, but only for the *view's*
        // copy: this model has to know where the caret is now, or the panel it just opened is
        // still resolving against the position the author left.
        update(for: document)
    }

    /// Whether this UTF-16 unit is the whitespace ``MentionDraft`` requires before a trigger.
    ///
    /// The same test the draft's own scan makes, so the two cannot disagree about what opens
    /// a word — a lone surrogate is not whitespace, and the space this inserts in front of one
    /// is harmless.
    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Clears the panel — and only *writes* when something actually changes.
    ///
    /// Observation's setters publish unconditionally, so assigning an already-empty
    /// array here invalidated the panel once per incoming message, forever, for a view
    /// whose content had not moved.
    func dismiss() {
        if activeRange != nil { activeRange = nil }
        if !suggestions.isEmpty { suggestions = [] }
    }

    func dismissComposer() {
        isComposerFocused = false
        dismiss()
    }

    private func apply(users: [IndexedSuggestion], channels: [IndexedSuggestion]) {
        userIndex = users
        channelIndex = channels
        refresh()
    }

    private func refresh() {
        guard let mention = document.activeMention(at: cursor) else {
            dismiss()
            return
        }
        if activeRange != mention.range { activeRange = mention.range }
        let query = Self.normalized(mention.query)
        let index = mention.kind == .user ? userIndex : channelIndex
        let matches = bestMatches(in: index, for: query, limit: 8)
        if matches != suggestions { suggestions = matches }
    }

    /// Keeps only the best few matches while scanning the pre-normalized index.
    /// Autocomplete never sorts an entire large roster on the main actor.
    private func bestMatches(
        in index: [IndexedSuggestion],
        for query: String,
        limit: Int
    ) -> [MentionSuggestion] {
        var best: [RankedSuggestion] = []
        for item in index {
            guard let score = item.score(for: query) else { continue }
            let ranked = RankedSuggestion(
                suggestion: item.suggestion,
                group: item.group,
                score: score,
                recencyRank: item.recencyRank,
                originalOrder: item.originalOrder
            )
            let insertion = best.firstIndex { ranked.precedes($0) } ?? best.endIndex
            guard insertion < limit else { continue }
            best.insert(ranked, at: insertion)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.suggestion)
    }

    nonisolated fileprivate static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    /// How deep the recency signal reaches. Comfortably past the eight rows the panel
    /// draws, so the ordering among the people an author actually works with is real
    /// rather than truncated — and short enough that the store read stays a small one.
    ///
    /// `nonisolated` because the read it bounds happens on the concurrent reader, off
    /// this actor.
    nonisolated private static let recencyDepth = 20
}

/// One indexed row: the normalized strings matching scans, computed off the main actor
/// when the store hands over a new snapshot — never per keystroke, and never on the
/// actor that has to draw the next frame.
private struct IndexedSuggestion: Sendable {
    let suggestion: MentionSuggestion
    let name: String
    let secondary: String
    let words: [String]
    let identifier: String
    let group: Int
    /// How recently this identity was last `@`-named, `0` being the most recent, and
    /// `Int.max` for someone who never has been — so "never mentioned" sorts after every
    /// mention without needing a second optional to unwrap on every comparison.
    let recencyRank: Int
    let originalOrder: Int

    init(_ suggestion: MentionSuggestion, originalOrder: Int, recent: RecentMentions) {
        self.suggestion = suggestion
        name = MentionAutocompleteModel.normalized(suggestion.label)
        secondary = MentionAutocompleteModel.normalized(suggestion.matchSecondary)
        words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }.map(String.init)
        identifier = suggestion.matchIdentifier.lowercased()
        group = suggestion.rankingGroup
        // Channels are never ranked by recency: a `#` token completes against its own
        // index, which this signal says nothing about.
        recencyRank = suggestion.kind == .user
            ? (recent.rank(of: suggestion.entityID) ?? .max)
            : .max
        self.originalOrder = originalOrder
    }

    /// Lower is better. Exact name, then name prefix, then a whole interior word,
    /// then an interior word's prefix, then the raw identifier — the Phase-4 ranking,
    /// now applied to channels as well as people.
    func score(for query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        if name == query || secondary == query { return 0 }
        if name.hasPrefix(query) || secondary.hasPrefix(query) { return 1 }
        if words.contains(query) { return 2 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 3 }
        if !identifier.isEmpty, identifier.hasPrefix(query) { return 4 }
        return nil
    }
}

private struct RankedSuggestion {
    let suggestion: MentionSuggestion
    let group: Int
    let score: Int
    let recencyRank: Int
    let originalOrder: Int

    /// Match quality first, then who was named most recently, then the membership
    /// grouping, then the read's own alphabetical order.
    ///
    /// Recency sits *above* `group` and below `score` on purpose. Above `group`, because
    /// having just named someone is a stronger statement about who you mean than whether
    /// they are a member or an agent — and because with no query typed every candidate
    /// scores 0, which is precisely what makes the first three rows the three people you
    /// mentioned most recently. Below `score`, because a name you are halfway through
    /// typing is a stronger statement still: nobody wants last week's colleague on top of
    /// the person whose name they are spelling out.
    ///
    /// Where there is no recency to speak of the tuple collapses to the original
    /// `(group, score, originalOrder)`, so a fresh install ranks exactly as before.
    func precedes(_ other: RankedSuggestion) -> Bool {
        (score, recencyRank, group, originalOrder)
            < (other.score, other.recencyRank, other.group, other.originalOrder)
    }
}
