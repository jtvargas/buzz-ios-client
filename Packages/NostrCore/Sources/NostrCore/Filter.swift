import Foundation

/// A NIP-01 subscription filter.
///
/// Within one filter, fields are ANDed and the values inside a field are ORed;
/// an absent field places no constraint, so an empty filter asks for everything
/// the relay is willing to serve. NIP-50 adds the free-text `search` field, kept
/// here because Buzz's one-shot search subscriptions use it.
///
/// This is deliberately plain NIP-01. The NIP-CW composite `(until, before_id)`
/// cursor travels over HTTP and is modelled in the BuzzKit layer that wraps this
/// type, not here — keeping `Filter` a faithful relay-subscription shape.
public struct Filter: Codable, Hashable, Sendable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [EventKind]?
    public var since: Int64?
    public var until: Int64?
    public var limit: Int?
    public var search: String?

    /// Single-letter tag constraints, keyed by the tag letter without its `#`.
    ///
    /// Held apart from the scalar fields because NIP-01 spells them on the wire
    /// as dynamic `#e` / `#p` / `#h` keys, which no fixed `CodingKeys` set can
    /// name. An entry `["h": ["group-1"]]` encodes to `"#h": ["group-1"]`.
    public var tagQueries: [String: [String]]

    public init(
        ids: [String]? = nil,
        authors: [String]? = nil,
        kinds: [EventKind]? = nil,
        since: Int64? = nil,
        until: Int64? = nil,
        limit: Int? = nil,
        search: String? = nil,
        tagQueries: [String: [String]] = [:]
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.since = since
        self.until = until
        self.limit = limit
        self.search = search
        self.tagQueries = tagQueries
    }

    // MARK: - Builders

    /// Scopes the filter to a NIP-29 group through its `h` tag.
    public func inGroup(_ groupID: String) -> Filter {
        withTagQuery("h", [groupID])
    }

    /// Scopes the filter to events that tag a pubkey.
    ///
    /// Mandatory, not optional, for the p-gated kinds below: a Buzz relay refuses
    /// a global subscription for those unless it carries a `#p` naming the
    /// authenticated user. Missing it fails the subscription rather than leaking
    /// anything, so it is worth catching before the frame goes out.
    public func taggingPubkey(_ pubkey: String) -> Filter {
        withTagQuery("p", [pubkey])
    }

    /// Scopes the filter to events referencing another event by id.
    public func referencingEvent(_ eventID: String) -> Filter {
        withTagQuery("e", [eventID])
    }

    /// Returns a copy carrying an arbitrary single-letter tag query.
    public func withTagQuery(_ name: String, _ values: [String]) -> Filter {
        var copy = self
        copy.tagQueries[name] = values
        return copy
    }

    // MARK: - Pre-send validation

    /// Kinds a relay will not serve globally: it demands a `#p` query scoped to
    /// the authenticated user before it returns any of them.
    public static let pubkeyGatedKinds: Set<EventKind> = [
        .giftWrap, .memberAdded, .memberRemoved,
    ]

    /// True when the filter asks for a p-gated kind without a `#p` scope, which a
    /// relay would reject. Checking this before sending turns a silent
    /// subscription failure into a caught programmer error.
    public var needsPubkeyScope: Bool {
        guard let kinds, kinds.contains(where: { Self.pubkeyGatedKinds.contains($0) }) else {
            return false
        }
        return tagQueries["p"]?.isEmpty != false
    }

    // MARK: - Canonical form

    /// Encodes with sorted keys, giving byte-identical output for equal filters.
    ///
    /// `JSONEncoder` makes no key-ordering promise for keyed containers, so two
    /// encodes of the same filter can differ byte for byte. Anything that treats
    /// a filter as a string — subscription dedup keys, cache keys, log lines —
    /// must route through this; a plain value comparison should use `Hashable`.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: - Codable

    /// A coding key that carries any string, needed for the dynamic `#x` tag
    /// keys that a fixed enum cannot spell.
    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        ids = try container.decodeIfPresent([String].self, forKey: .init(stringValue: "ids"))
        authors = try container.decodeIfPresent([String].self, forKey: .init(stringValue: "authors"))
        kinds = try container.decodeIfPresent([EventKind].self, forKey: .init(stringValue: "kinds"))
        since = try container.decodeIfPresent(Int64.self, forKey: .init(stringValue: "since"))
        until = try container.decodeIfPresent(Int64.self, forKey: .init(stringValue: "until"))
        limit = try container.decodeIfPresent(Int.self, forKey: .init(stringValue: "limit"))
        search = try container.decodeIfPresent(String.self, forKey: .init(stringValue: "search"))

        var collected: [String: [String]] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("#") {
            let name = String(key.stringValue.dropFirst())
            collected[name] = try container.decode([String].self, forKey: key)
        }
        tagQueries = collected
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)

        // Only non-nil scalar fields reach the wire; an omitted field is an
        // absent constraint, whereas an encoded null would be a decode error at
        // most relays.
        try container.encodeIfPresent(ids, forKey: .init(stringValue: "ids"))
        try container.encodeIfPresent(authors, forKey: .init(stringValue: "authors"))
        try container.encodeIfPresent(kinds, forKey: .init(stringValue: "kinds"))
        try container.encodeIfPresent(since, forKey: .init(stringValue: "since"))
        try container.encodeIfPresent(until, forKey: .init(stringValue: "until"))
        try container.encodeIfPresent(limit, forKey: .init(stringValue: "limit"))
        try container.encodeIfPresent(search, forKey: .init(stringValue: "search"))

        // Sorted so that repeated encodes of one filter are stable, which keeps
        // subscription dedup and test assertions from depending on dictionary
        // iteration order.
        for name in tagQueries.keys.sorted() {
            try container.encode(tagQueries[name], forKey: .init(stringValue: "#\(name)"))
        }
    }
}
