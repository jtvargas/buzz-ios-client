import Foundation
import GRDB

/// Which visible text produced a people or channel result.
public enum LocalSearchField: Sendable, Hashable {
    case name
    case agentName
    case nip05
    case description
    case topic
}

/// The exact people/channel text and ranges the App should highlight.
public struct LocalSearchTextMatch: Sendable, Hashable {
    public let field: LocalSearchField
    public let text: String
    public let ranges: [SearchMatchRange]
}

public struct PersonSearchHit: Sendable, Hashable, Identifiable {
    public let person: DirectoryEntity
    public let match: LocalSearchTextMatch
    public let rank: Int

    public var id: String { person.id }
}

public struct ChannelSearchHit: Sendable, Hashable, Identifiable {
    public let channel: BrowsableChannel
    public let match: LocalSearchTextMatch
    public let rank: Int

    public var id: String { channel.id }
}

public struct LocalSearchResults: Sendable, Hashable {
    public let messages: [MessageSearchHit]
    public let people: [PersonSearchHit]
    public let channels: [ChannelSearchHit]

    public static let empty = LocalSearchResults(messages: [], people: [], channels: [])

    public init(
        messages: [MessageSearchHit],
        people: [PersonSearchHit],
        channels: [ChannelSearchHit]
    ) {
        self.messages = messages
        self.people = people
        self.channels = channels
    }
}

public extension BuzzEventStore {
    /// Searches local messages, people, and channels from one database snapshot.
    ///
    /// Messages use the durable FTS5 index. People and channels are deliberately
    /// scan-and-score reads over the already-small directory projections: they keep
    /// typeahead substring behavior without paying the storage and write cost of a
    /// second prefix index.
    nonisolated func searchLocal(
        query: String,
        selfPubkey: String,
        channelID: String? = nil,
        limit: Int = 20
    ) throws -> LocalSearchResults {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let matchQuery = Self.ftsMatchQuery(text) else { return .empty }
        let boundedLimit = min(max(limit, 1), 100)
        let markers = SearchHighlightMarkers()

        return try reader.read { db in
            LocalSearchResults(
                messages: try Self.fetchMessageSearch(
                    db,
                    match: matchQuery,
                    channelID: channelID,
                    limit: boundedLimit,
                    markers: markers
                ),
                people: Self.searchPeople(
                    Self.fetchDirectorySnapshot(db, selfPubkey: selfPubkey),
                    query: text,
                    limit: boundedLimit
                ),
                channels: try Self.searchChannels(
                    Self.fetchBrowsableChannels(db, identity: selfPubkey),
                    query: text,
                    limit: boundedLimit
                )
            )
        }
    }
}

private extension BuzzEventStore {
    static func searchPeople(
        _ directory: DirectorySnapshot,
        query: String,
        limit: Int
    ) -> [PersonSearchHit] {
        directory.entities.values.compactMap { person in
            let fields: [SearchFieldCandidate] = [
                SearchFieldCandidate(field: .name, text: person.profileName, rank: 0),
                SearchFieldCandidate(field: .agentName, text: person.agentName, rank: 10),
                SearchFieldCandidate(field: .nip05, text: person.nip05, rank: 20),
            ]
            return bestMatch(in: fields, query: query).map { match in
                PersonSearchHit(person: person, match: match.value, rank: match.rank)
            }
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.id < rhs.id
        }
        .prefix(limit)
        .map { $0 }
    }

    static func searchChannels(
        _ channels: [BrowsableChannel],
        query: String,
        limit: Int
    ) -> [ChannelSearchHit] {
        channels.compactMap { channel in
            let fields: [SearchFieldCandidate] = [
                SearchFieldCandidate(field: .name, text: channel.name, rank: 0),
                SearchFieldCandidate(field: .description, text: channel.about, rank: 10),
                SearchFieldCandidate(field: .topic, text: channel.topic, rank: 20),
            ]
            return bestMatch(in: fields, query: query).map { match in
                ChannelSearchHit(channel: channel, match: match.value, rank: match.rank)
            }
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.id < rhs.id
        }
        .prefix(limit)
        .map { $0 }
    }

    static func bestMatch(
        in fields: [SearchFieldCandidate],
        query: String
    ) -> (value: LocalSearchTextMatch, rank: Int)? {
        fields.compactMap { candidate in
            guard let rawText = candidate.text,
                  let text = rawText.nilIfSearchEmpty,
                  let match = text.searchMatch(for: query)
            else { return nil }
            return (
                LocalSearchTextMatch(field: candidate.field, text: text, ranges: match.ranges),
                candidate.rank + match.rank
            )
        }
        .min { lhs, rhs in lhs.1 < rhs.1 }
    }
}

private struct SearchFieldCandidate {
    let field: LocalSearchField
    let text: String?
    let rank: Int
}

private extension String {
    var nilIfSearchEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func searchMatch(for query: String) -> (ranges: [SearchMatchRange], rank: Int)? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let first = range(of: query, options: options) else { return nil }

        let rank: Int
        if first.lowerBound == startIndex, first.upperBound == endIndex {
            rank = 0
        } else if first.lowerBound == startIndex {
            rank = 1
        } else if first.lowerBound > startIndex,
                  self[index(before: first.lowerBound)].isSearchSeparator {
            rank = 2
        } else {
            rank = 3
        }

        var ranges: [SearchMatchRange] = []
        var cursor = startIndex
        while cursor < endIndex,
              let found = range(of: query, options: options, range: cursor ..< endIndex) {
            ranges.append(SearchMatchRange(
                location: self[..<found.lowerBound].utf16.count,
                length: self[found].utf16.count
            ))
            cursor = found.upperBound
        }
        return (ranges, rank)
    }
}

private extension Character {
    var isSearchSeparator: Bool {
        isWhitespace || self == "-" || self == "_" || self == "." || self == "/"
    }
}
