import Foundation
import GRDB
import NostrCore

/// A match inside a search result's UTF-16 representation.
///
/// UTF-16 offsets cross the BuzzKit/App boundary without carrying a `String.Index`
/// tied to another value. The App can turn this into `NSRange` and then into ranges
/// of the exact result text it was returned beside.
public struct SearchMatchRange: Sendable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// One locally indexed message whose current visible text matched the query.
public struct MessageSearchHit: Sendable, Hashable, Identifiable {
    public let id: String
    public let channelID: String
    public let pubkey: String
    public let createdAt: Int64
    /// A bounded excerpt centered on one best match, not the full message body.
    public let content: String
    public let matchRanges: [SearchMatchRange]
    /// FTS5's bm25 score. Lower values rank ahead of higher ones.
    public let rank: Double
    public let authorName: String?
    public let authorPicture: String?
    /// The relay-authored channel type, not a roster-count inference.
    public let isDirectMessage: Bool
    /// The thread this message lives inside, when it lives inside one *and nowhere else*.
    ///
    /// The index covers every message; the channel timeline does not. A non-broadcast
    /// reply is deliberately excluded from its channel's page — see the `NOT EXISTS`
    /// against `thread` in ``fetchTimeline(_:channel:before:limit:selfPubkey:)`` — so a
    /// caller that opens the channel to show one of these opens a surface the message can
    /// never appear in. This is what lets the caller open the thread instead.
    ///
    /// `nil` for anything reachable in its channel, which includes a *broadcast* reply:
    /// it has a `thread` row too, and the timeline lets it through, so routing it to a
    /// thread would move it away from where its author put it.
    public let threadRootID: String?
}

public extension BuzzEventStore {
    /// Searches current, locally stored message text with FTS5 relevance ranking.
    ///
    /// The index contains immutable original and edit events. This query is where
    /// they become a current message: only the original or the newest authorized
    /// edit may pass, and the timeline's deletion predicate removes tombstones.
    /// FTS ranks a 10x candidate window first so authorization work stays bounded.
    /// Because hidden rows can exhaust that window, fewer than `limit` hits may be
    /// returned even when lower-ranked visible matches exist. Deleted messages and
    /// edits are rare enough that preserving bounded query cost is the better trade.
    ///
    /// Terms are quoted individually, so authored FTS syntax is text rather than an
    /// operator language. A bounded term count also keeps untrusted input from
    /// constructing an arbitrarily expensive expression.
    nonisolated func searchMessages(
        query: String,
        channelID: String? = nil,
        limit: Int = 20
    ) throws -> [MessageSearchHit] {
        guard let match = Self.ftsMatchQuery(query) else { return [] }
        let markers = SearchHighlightMarkers()
        let boundedLimit = min(max(limit, 1), 100)

        return try reader.read { db in
            try Self.fetchMessageSearch(
                db,
                match: match,
                channelID: channelID,
                limit: boundedLimit,
                markers: markers
            )
        }
    }
}

extension BuzzEventStore {
    static let maxSearchTerms = 16
    static let searchCandidateWindowMultiplier = 10
    /// One best 18-token window keeps a typical excerpt inside the row's three lines.
    static let searchSnippetTokenCount = 18

    static func fetchMessageSearch(
        _ db: Database,
        match: String,
        channelID: String?,
        limit: Int,
        markers: SearchHighlightMarkers
    ) throws -> [MessageSearchHit] {
        let candidateWindow = limit * searchCandidateWindowMultiplier
        let rows = try Row.fetchAll(
            db,
            sql: messageSearchSQL(channelScoped: channelID != nil),
            arguments: [
                "match": match,
                "open": markers.open,
                "close": markers.close,
                "snippetTokens": searchSnippetTokenCount,
                "channelID": channelID,
                "limit": limit,
                "window": candidateWindow,
                "messageKind": EventKind.channelMessage.rawValue,
                "editKind": EventKind.messageEdit.rawValue,
            ]
        )
        return rows.compactMap { row in
            let marked: String = row["marked_content"]
            let storedChannelID: String? = row["channel_id"]
            guard let highlighted = decodeHighlight(marked, markers: markers),
                  let storedChannelID
            else { return nil }

            return MessageSearchHit(
                id: row["id"],
                channelID: storedChannelID,
                pubkey: row["pubkey"],
                createdAt: row["created_at"],
                content: highlighted.content,
                matchRanges: highlighted.ranges,
                rank: row["rank"],
                authorName: row["display_name"],
                authorPicture: row["picture"],
                isDirectMessage: row["is_dm"] ?? false,
                threadRootID: row["thread_root_id"]
            )
        }
    }

    static func messageSearchSQL(channelScoped: Bool) -> String {
        let currentEdit = newestAuthorizedEditEventID(
            target: "target.id", author: "target.pubkey", owner: "owner.owner_pubkey"
        )
        let deleted = deletionApplies(
            target: "target.id", author: "target.pubkey", owner: "owner.owner_pubkey"
        )

        return """
        WITH candidate AS (
            SELECT message_search.rowid AS source_rowid,
                   bm25(message_search) AS rank,
                   snippet(
                       message_search, 0, :open, :close, '…', :snippetTokens
                   ) AS marked_content
              FROM message_search
        \(messageSearchCandidateScope(channelScoped: channelScoped))
             ORDER BY bm25(message_search)
             LIMIT :window
        )
        SELECT target.id AS id,
               target.h AS channel_id,
               target.pubkey AS pubkey,
               target.created_at AS created_at,
               candidate.marked_content AS marked_content,
               candidate.rank AS rank,
               profile.display_name AS display_name,
               profile.picture AS picture,
               COALESCE(channel.channel_type = 'dm', 0) AS is_dm,
               reply.root_id AS thread_root_id
        \(messageSearchHitJoins)
         WHERE source.id = COALESCE(\(currentEdit), target.id)
           AND NOT \(deleted)
         ORDER BY rank, target.created_at DESC, target.id DESC
         LIMIT :limit
        """
    }

    /// Resolving one FTS candidate row into the message it stands for, and everything the
    /// caller needs to name and route that message.
    ///
    /// Its own constant because the query around it is a `LIMIT` and an `ORDER BY` on top of
    /// exactly this; keeping the resolution in one piece is also what makes it obvious that
    /// the last join is the only one that decides anything.
    static let messageSearchHitJoins = """
      FROM candidate
      JOIN event source ON source.rowid = candidate.source_rowid
      LEFT JOIN edit source_edit ON source_edit.event_id = source.id
      JOIN event target
        ON target.id = CASE source.kind
            WHEN :messageKind THEN source.id
            WHEN :editKind THEN source_edit.target_id
           END
       AND target.kind = :messageKind
      LEFT JOIN event_owner owner ON owner.event_id = target.id
      LEFT JOIN profile ON profile.pubkey = target.pubkey
      LEFT JOIN channel ON channel.id = target.h
      -- The mirror image of the channel page's own exclusion: this returns a root for
      -- exactly the messages `fetchTimeline` refuses to show, and for nothing else, so a
      -- caller can tell "open the channel" from "open the thread" without a second read.
      -- `broadcast = 0` belongs on the join and not in the `WHERE`, or a broadcast reply
      -- would fail the condition and drop out of the results altogether.
      LEFT JOIN thread reply
        ON reply.event_id = target.id AND reply.broadcast = 0
    """

    static func messageSearchCandidateScope(channelScoped: Bool) -> String {
        if !channelScoped {
            return """
             WHERE message_search MATCH :match
               AND :channelID IS NULL
            """
        }

        return """
          JOIN event candidate_source ON candidate_source.rowid = message_search.rowid
          LEFT JOIN edit candidate_source_edit
            ON candidate_source_edit.event_id = candidate_source.id
          JOIN event candidate_target
            ON candidate_target.id = CASE candidate_source.kind
                WHEN :messageKind THEN candidate_source.id
                WHEN :editKind THEN candidate_source_edit.target_id
               END
           AND candidate_target.kind = :messageKind
         WHERE message_search MATCH :match
           AND candidate_target.h = :channelID
        """
    }

    static func ftsMatchQuery(_ query: String) -> String? {
        let terms = query
            .split(whereSeparator: \Character.isWhitespace)
            .prefix(maxSearchTerms)
            .map { term in
                "\"\(String(term).replacingOccurrences(of: "\"", with: "\"\""))\""
            }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
    }

    static func decodeHighlight(
        _ marked: String,
        markers: SearchHighlightMarkers
    ) -> (content: String, ranges: [SearchMatchRange])? {
        var content = ""
        var ranges: [SearchMatchRange] = []
        var cursor = marked.startIndex

        while let opening = marked.range(of: markers.open, range: cursor ..< marked.endIndex) {
            let prefix = marked[cursor ..< opening.lowerBound]
            content.append(contentsOf: prefix)

            guard let closing = marked.range(
                of: markers.close,
                range: opening.upperBound ..< marked.endIndex
            ) else { return nil }

            let matched = marked[opening.upperBound ..< closing.lowerBound]
            let location = content.utf16.count
            content.append(contentsOf: matched)
            ranges.append(SearchMatchRange(location: location, length: matched.utf16.count))
            cursor = closing.upperBound
        }

        content.append(contentsOf: marked[cursor...])
        return (content, ranges)
    }
}

struct SearchHighlightMarkers {
    let open: String
    let close: String

    init() {
        let nonce = UUID().uuidString
        open = "\u{001E}\(nonce):open\u{001E}"
        close = "\u{001E}\(nonce):close\u{001E}"
    }
}
