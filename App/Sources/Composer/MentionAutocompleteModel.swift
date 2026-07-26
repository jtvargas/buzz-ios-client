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
    private(set) var activeRange: NSRange?
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
                await apply(users: candidates, channels: channels)
            }
        } catch {
            // Cancellation/teardown leaves the latest candidate snapshot visible.
        }
    }

    func update(for document: MentionDraft) {
        self.document = document
        refresh()
    }

    func select(_ suggestion: MentionSuggestion, in document: inout MentionDraft) {
        guard let activeRange else { return }
        document.insert(suggestion, replacing: activeRange)
        update(for: document)
    }

    func dismiss() {
        activeRange = nil
        suggestions = []
    }

    func dismissComposer() {
        isComposerFocused = false
        dismiss()
    }

    private func apply(users: [MentionCandidateProfile], channels: [ChannelSuggestion]) {
        userIndex = users.enumerated().map {
            IndexedSuggestion(.user($1), originalOrder: $0)
        }
        channelIndex = channels.enumerated().map {
            IndexedSuggestion(.channel($1), originalOrder: $0)
        }
        refresh()
    }

    private func refresh() {
        guard let mention = document.trailingMention() else {
            dismiss()
            return
        }
        activeRange = mention.range
        let query = Self.normalized(mention.query)
        let index = mention.kind == .user ? userIndex : channelIndex
        suggestions = bestMatches(in: index, for: query, limit: 8)
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
}

/// One indexed row: the normalized strings matching scans, computed once when the
/// store hands over a new snapshot rather than per keystroke.
private struct IndexedSuggestion {
    let suggestion: MentionSuggestion
    let name: String
    let secondary: String
    let words: [String]
    let identifier: String
    let group: Int
    let originalOrder: Int

    init(_ suggestion: MentionSuggestion, originalOrder: Int) {
        self.suggestion = suggestion
        name = MentionAutocompleteModel.normalized(suggestion.label)
        secondary = MentionAutocompleteModel.normalized(suggestion.matchSecondary)
        words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }.map(String.init)
        identifier = suggestion.matchIdentifier.lowercased()
        group = suggestion.rankingGroup
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
        if identifier.hasPrefix(query) { return 4 }
        return nil
    }
}

private struct RankedSuggestion {
    let suggestion: MentionSuggestion
    let group: Int
    let score: Int
    let originalOrder: Int

    func precedes(_ other: RankedSuggestion) -> Bool {
        (group, score, originalOrder) < (other.group, other.score, other.originalOrder)
    }
}
