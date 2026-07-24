import Foundation
import NostrCore

/// A position in a channel's total order, as NIP-CW defines it: the composite
/// `(created_at, id)` pair.
///
/// `created_at` alone is lossy — a relay hands out many events in one second, and
/// a timestamp-only cursor skips or repeats them at every page boundary. The event
/// id breaks those ties bytewise, which is the whole reason the window path exists.
public struct WindowCursor: Sendable, Equatable, Hashable {
    public let createdAt: Int64
    /// The 64-character lowercase-hex event id.
    public let id: String

    public init(createdAt: Int64, id: String) {
        self.createdAt = createdAt
        self.id = id
    }

    /// The canonical cursor serialization used in a `kind:39006` `d`-tag suffix:
    /// `<created_at>:<id>` (decimal seconds, colon, lowercase hex id).
    var dTagSuffix: String {
        "\(createdAt):\(id)"
    }
}

/// Which page of a channel window a request asks for.
///
/// Modelled as an enum rather than an optional pair so the NIP's "both or neither"
/// rule (`until` + `before_id` present together or absent together, NIP-CW §Request)
/// is unrepresentable to violate: ``head`` sends neither cursor field, ``after(_:)``
/// sends both. A half cursor cannot be constructed.
public enum WindowRequestCursor: Sendable, Equatable, Hashable {
    /// The head of the channel — no cursor fields on the wire.
    case head
    /// The page continuing from a previous page's `next_cursor`, echoed verbatim.
    case after(WindowCursor)

    /// The `d`-tag suffix a served `kind:39006` MUST echo for this request: the
    /// literal `head`, or the composite cursor's `<created_at>:<id>` form
    /// (NIP-CW §Overlay Event Formats).
    var dTagSuffix: String {
        switch self {
        case .head: "head"
        case let .after(cursor): cursor.dTagSuffix
        }
    }
}

/// A NIP-CW channel-window request: a plain NIP-01 filter plus the extension
/// fields that select and page the relay-computed top-level timeline.
///
/// This is the BuzzKit type ``Filter`` deliberately is not — NostrCore keeps
/// ``Filter`` a faithful relay-subscription shape and defers the window cursor to
/// here (`Filter.swift`). The extension fields (`top_level`, `include_summaries`,
/// `include_aux`, and the composite `until` + `before_id` cursor) ride an HTTP
/// `POST /query` body, never a socket REQ, so they belong at this layer.
///
/// The request encodes to the query surface's ordinary body shape: a JSON array of
/// one filter object carrying both the standard keys and the extension keys
/// (``encodedRequestBody()``).
public struct WindowFilter: Sendable, Equatable, Hashable {
    /// The single channel the window targets. NIP-CW requires exactly one `#h`; a
    /// window over zero or several channels is a protocol error the relay rejects.
    public var channelID: String

    /// Optional restriction on which kinds may be *rows*. It does not constrain the
    /// aux closure or the overlay kinds, which the relay appends regardless.
    public var kinds: [EventKind]?

    /// The row budget — top-level rows only, never overlays or aux events. The
    /// relay clamps it to its documented range (Buzz: default 50, max 200).
    public var limit: Int

    /// Whether to request the `kind:39005` thread-summary overlays.
    public var includeSummaries: Bool

    /// Whether to request the aux closure (reactions, deletions, edits of the rows).
    public var includeAux: Bool

    /// Which page this request asks for — head, or a continuation cursor.
    public var cursor: WindowRequestCursor

    /// - Parameters:
    ///   - channelID: the single channel (`#h`) the window targets.
    ///   - cursor: the page to fetch; defaults to the head of the channel.
    ///   - kinds: optional row-kind restriction; defaults to channel messages.
    ///   - limit: the row budget; defaults to the NIP-CW-recommended 50.
    ///   - includeSummaries: request `kind:39005` overlays; defaults to `true`.
    ///   - includeAux: request the aux closure; defaults to `true`.
    public init(
        channelID: String,
        cursor: WindowRequestCursor = .head,
        kinds: [EventKind]? = [.channelMessage],
        limit: Int = 50,
        includeSummaries: Bool = true,
        includeAux: Bool = true
    ) {
        self.channelID = channelID
        self.cursor = cursor
        self.kinds = kinds
        self.limit = limit
        self.includeSummaries = includeSummaries
        self.includeAux = includeAux
    }

    // MARK: - Derived shapes

    /// The plain NIP-01 filter underneath — `kinds` + `#h` + `limit` (and `until`
    /// for a cursored page) with every NIP-CW extension key stripped.
    ///
    /// This is exactly the "clean standard filter" a client reissues when the
    /// window path degrades (NIP-CW §Degradation): all extension keys removed,
    /// threads reassembled client-side. Exposing it here lets the step-6 engine's
    /// fallback reuse the request's standard projection verbatim rather than
    /// rebuild it. `before_id` — an extension key — is dropped; `until` is standard
    /// NIP-01 and kept.
    public var baseFilter: Filter {
        var filter = Filter(kinds: kinds, limit: limit, tagQueries: ["h": [channelID]])
        if case let .after(cursor) = cursor {
            filter.until = cursor.createdAt
        }
        return filter
    }

    /// The `kind:39006` `d`-tag value a served response MUST carry for this
    /// request: `<channel-id>:<request-cursor-or-head>`. The parser compares the
    /// overlay's `d` tag against this to bind each page to the request it answered.
    var expectedBoundsDTag: String {
        "\(channelID):\(cursor.dTagSuffix)"
    }

    // MARK: - Wire encoding

    /// The `POST /query` request body: a JSON array of one filter object carrying
    /// the standard keys and the NIP-CW extension keys.
    ///
    /// The query surface takes an array of filters (as the standard read path
    /// does); a window is always exactly one. Keys are sorted so the bytes are
    /// stable — useful for logging, and harmless to the NIP-98 signature, which is
    /// computed over whatever bytes this returns.
    func encodedRequestBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode([self])
    }
}

// MARK: - Encodable

extension WindowFilter: Encodable {
    /// A coding key carrying any string, needed for the dynamic `#h` tag key and
    /// the snake-cased extension keys a fixed enum cannot spell alongside them.
    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)

        // Standard NIP-01 keys. `kinds` restricts rows only; an absent list lets
        // the relay pick the row kinds for the channel.
        try container.encodeIfPresent(kinds, forKey: DynamicKey("kinds"))
        try container.encode([channelID], forKey: DynamicKey("#h"))
        try container.encode(limit, forKey: DynamicKey("limit"))

        // Extension keys. `top_level` MUST be the boolean `true` to select the
        // window path; any other value demotes the filter to a plain query.
        try container.encode(true, forKey: DynamicKey("top_level"))
        try container.encode(includeSummaries, forKey: DynamicKey("include_summaries"))
        try container.encode(includeAux, forKey: DynamicKey("include_aux"))

        // The composite cursor: both fields for a continuation, neither for head.
        // The enum makes the "both or neither" rule structural.
        if case let .after(cursor) = cursor {
            try container.encode(cursor.createdAt, forKey: DynamicKey("until"))
            try container.encode(cursor.id, forKey: DynamicKey("before_id"))
        }
    }
}
