import Foundation
import NostrCore

/// One NIP-50 message hit, in the relay's relevance order.
public struct RelayMessageSearchHit: Sendable, Hashable, Identifiable {
    public let id: String
    public let channelID: String
    public let pubkey: String
    public let createdAt: Int64
    /// A bounded excerpt centered on the first match, not the full message body.
    public let content: String
    public let matchRanges: [SearchMatchRange]
    /// The event's arrival position. NIP-50 exposes relevance through order only: the relay
    /// computes a numeric rank but sends no score on the wire.
    public let ordinal: Int

    public init(
        id: String,
        channelID: String,
        pubkey: String,
        createdAt: Int64,
        content: String,
        matchRanges: [SearchMatchRange],
        ordinal: Int
    ) {
        self.id = id
        self.channelID = channelID
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.content = content
        self.matchRanges = matchRanges
        self.ordinal = ordinal
    }
}

public extension SyncEngine {
    /// Searches beyond the local log while preserving the relay's relevance order.
    ///
    /// `SubscriptionManager.query` returns events in frame-arrival order. The ordinal is
    /// captured immediately from that array, before any store write or read can re-sort the
    /// events by timestamp and silently discard the only ranking signal on the wire.
    func searchRelayMessages(query: String, limit: Int = 20) async throws -> [RelayMessageSearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        let boundedLimit = min(max(limit, 1), 100)
        let events = try await subscriptions.query([
            Filter(kinds: [.channelMessage], limit: boundedLimit, search: text),
        ])

        return events.enumerated().compactMap { ordinal, event in
            guard event.kind == .channelMessage, event.isValid, let channelID = event.groupID else {
                return nil
            }
            let snippet = Self.searchSnippet(in: event.content, terms: text)
            return RelayMessageSearchHit(
                id: event.id,
                channelID: channelID,
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                content: snippet.content,
                matchRanges: snippet.ranges,
                ordinal: ordinal
            )
        }
    }
}

private extension SyncEngine {
    /// A result row shows one relevant window rather than enumerating distant matches.
    /// Local FTS chooses its best window; relay hits use the first match in relay order.
    static func searchSnippet(
        in content: String,
        terms: String
    ) -> (content: String, ranges: [SearchMatchRange]) {
        let ranges = searchRanges(in: content, terms: terms)
        guard let first = ranges.first,
              let match = Range(NSRange(location: first.location, length: first.length), in: content)
        else { return (content, ranges) }

        var words: [Range<String.Index>] = []
        content.enumerateSubstrings(
            in: content.startIndex ..< content.endIndex,
            options: .byWords
        ) { _, range, _, _ in
            words.append(range)
        }
        guard words.count > BuzzEventStore.searchSnippetTokenCount else {
            return (content, ranges)
        }
        guard let matchIndex = words.firstIndex(where: { $0.overlaps(match) }) else {
            return (content, ranges)
        }

        let tokenCount = BuzzEventStore.searchSnippetTokenCount
        var lower = max(0, matchIndex - tokenCount / 2)
        let upper = min(words.count, lower + tokenCount)
        lower = max(0, upper - tokenCount)

        let excerptStart = lower == 0 ? content.startIndex : words[lower].lowerBound
        let excerptEnd = upper == words.count ? content.endIndex : words[upper - 1].upperBound
        var snippet = String(content[excerptStart ..< excerptEnd])
        if lower > 0 { snippet = "… \(snippet)" }
        if upper < words.count { snippet += " …" }
        return (snippet, searchRanges(in: snippet, terms: terms))
    }

    static func searchRanges(in content: String, terms: String) -> [SearchMatchRange] {
        terms.split(whereSeparator: \.isWhitespace).flatMap { term in
            var ranges: [SearchMatchRange] = []
            var remainder = content.startIndex..<content.endIndex
            while let match = content.range(
                of: String(term),
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remainder
            ) {
                let range = NSRange(match, in: content)
                ranges.append(SearchMatchRange(location: range.location, length: range.length))
                remainder = match.upperBound..<content.endIndex
            }
            return ranges
        }
        .sorted { lhs, rhs in lhs.location < rhs.location }
    }
}
