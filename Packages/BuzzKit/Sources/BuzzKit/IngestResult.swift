import NostrCore

/// What a batch ingest did with each event it was handed.
///
/// Reported rather than thrown: a batch off the wire routinely mixes fresh events,
/// duplicates from a reconnect overlap, ephemeral presence, and the occasional
/// malformed event a relay served. None of those is an error for the batch as a
/// whole, so the store returns an accounting the caller can act on — advancing a
/// cursor, surfacing rejections, forwarding ephemeral presence — instead of
/// failing the transaction.
public struct IngestResult: Sendable, Equatable {
    /// Ids of events newly written to the log.
    public var inserted: [String] = []

    /// Ids of events already present. Expected and harmless: reconnect overlap and
    /// echoes of our own sends both land here, made free by the content-addressed
    /// primary key.
    public var duplicates: [String] = []

    /// Ephemeral events (presence, typing) that were verified and then diverted.
    /// They are never written to the log; the caller forwards them to the
    /// in-memory presence store.
    public var ephemeral: [NostrEvent] = []

    /// Events that failed verification and were discarded, each with the reason.
    public var rejected: [Rejection] = []

    public init() {}

    /// Whether the batch produced no outcomes at all — an empty input, or one
    /// entirely elided before the write.
    public var isEmpty: Bool {
        inserted.isEmpty && duplicates.isEmpty && ephemeral.isEmpty && rejected.isEmpty
    }
}

/// A verification failure for one event, kept out of the log.
public struct Rejection: Sendable, Equatable {
    /// The id the event claimed. For an id mismatch this is the forged value, not
    /// a recomputed one — it is what the relay sent under.
    public let id: String
    public let reason: Reason

    public init(id: String, reason: Reason) {
        self.id = id
        self.reason = reason
    }

    public enum Reason: Sendable, Equatable {
        /// The claimed id is not the hash of the event's own fields, so a field was
        /// altered after signing — the classic relay content swap.
        case idMismatch
        /// The id is intact but the signature does not verify under the claimed
        /// author's key.
        case badSignature
    }
}
