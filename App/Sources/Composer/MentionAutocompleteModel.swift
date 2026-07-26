import BuzzKit
import Foundation
import GRDB
import Observation

/// Live, locally indexed mention candidates for one channel.
@MainActor
@Observable
final class MentionAutocompleteModel {
    private(set) var suggestions: [MentionCandidateProfile] = []
    private(set) var activeRange: NSRange?
    var isComposerFocused = false

    private let channel: String
    private let store: BuzzEventStore
    private let selfPubkey: String?
    private var index: [IndexedCandidate] = []
    private var document = MentionDraft()

    init(channel: String, store: BuzzEventStore, selfPubkey: String?) {
        self.channel = channel
        self.store = store
        self.selfPubkey = selfPubkey
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let candidates = (try? store.mentionCandidates(
                    channel: channel,
                    selfPubkey: selfPubkey
                )) ?? []
                await apply(candidates)
            }
        } catch {
            // Cancellation/teardown leaves the latest candidate snapshot visible.
        }
    }

    func update(for document: MentionDraft) {
        self.document = document
        refresh()
    }

    func select(_ candidate: MentionCandidateProfile, in document: inout MentionDraft) {
        guard let activeRange else { return }
        document.insert(candidate, replacing: activeRange)
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

    private func apply(_ candidates: [MentionCandidateProfile]) {
        index = candidates.enumerated().map(IndexedCandidate.init)
        refresh()
    }

    private func refresh() {
        guard let mention = document.trailingMention() else {
            dismiss()
            return
        }
        activeRange = mention.range
        let query = Self.normalized(mention.query)
        suggestions = bestMatches(for: query, limit: 8)
    }

    /// Keeps only the best few matches while scanning the pre-normalized index.
    /// Autocomplete never sorts an entire large roster on the main actor.
    private func bestMatches(for query: String, limit: Int) -> [MentionCandidateProfile] {
        var best: [RankedCandidate] = []
        for item in index {
            guard let score = item.score(for: query) else { continue }
            let ranked = RankedCandidate(
                candidate: item.candidate,
                group: item.candidate.isChannelMember ? 0 : (item.candidate.isAgent ? 2 : 1),
                score: score,
                originalOrder: item.originalOrder
            )
            let insertion = best.firstIndex { ranked.precedes($0) } ?? best.endIndex
            guard insertion < limit else { continue }
            best.insert(ranked, at: insertion)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.candidate)
    }

    nonisolated fileprivate static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private struct IndexedCandidate {
    let candidate: MentionCandidateProfile
    let name: String
    let secondary: String
    let words: [String]
    let originalOrder: Int

    init(_ offset: Int, _ candidate: MentionCandidateProfile) {
        self.candidate = candidate
        name = MentionAutocompleteModel.normalized(candidate.displayName)
        secondary = MentionAutocompleteModel.normalized(candidate.secondaryLabel ?? "")
        words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }.map(String.init)
        originalOrder = offset
    }

    func score(for query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        if name == query || secondary == query { return 0 }
        if name.hasPrefix(query) || secondary.hasPrefix(query) { return 1 }
        if words.contains(query) { return 2 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 3 }
        if candidate.pubkey.lowercased().hasPrefix(query) { return 4 }
        return nil
    }
}

private struct RankedCandidate {
    let candidate: MentionCandidateProfile
    let group: Int
    let score: Int
    let originalOrder: Int

    func precedes(_ other: RankedCandidate) -> Bool {
        (group, score, originalOrder) < (other.group, other.score, other.originalOrder)
    }
}
