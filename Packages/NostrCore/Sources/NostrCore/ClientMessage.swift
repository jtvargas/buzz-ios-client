import Foundation

/// A frame sent from client to relay (NIP-01, NIP-42).
///
/// Nostr frames are heterogeneous JSON arrays — a type tag followed by
/// positional fields — rather than objects, so both directions are coded by
/// hand against an unkeyed container. Encoding writes each element straight into
/// one `unkeyedContainer`, letting the embedded event and filters serialize
/// inline in a single pass with no intermediate `[Any]` or `JSONSerialization`
/// round trip.
public enum ClientMessage: Sendable, Equatable, Codable {
    /// Publish a signed event.
    case event(NostrEvent)
    /// Open a subscription: an id the client chooses, plus one or more filters.
    case req(subscriptionID: String, filters: [Filter])
    /// Close a subscription by its id.
    case close(subscriptionID: String)
    /// Answer a NIP-42 challenge with a signed kind-22242 event.
    case auth(NostrEvent)

    /// The wire bytes for this frame.
    ///
    /// Keys are sorted so a given frame serializes identically every time, which
    /// keeps logs and any frame-level equality checks stable. Ordering carries no
    /// protocol meaning: a relay recomputes an event's id from its canonical
    /// form, never from wire key order, so sorting here cannot affect acceptance.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: - Codable

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case let .event(event):
            try container.encode("EVENT")
            try container.encode(event)
        case let .auth(event):
            try container.encode("AUTH")
            try container.encode(event)
        case let .close(subscriptionID):
            try container.encode("CLOSE")
            try container.encode(subscriptionID)
        case let .req(subscriptionID, filters):
            try container.encode("REQ")
            try container.encode(subscriptionID)
            for filter in filters {
                try container.encode(filter)
            }
        }
    }

    /// Decoding exists chiefly for tests and the scripted relay double; the
    /// client is the sole author of these frames in production. Unlike relay
    /// frames, the input here is trusted, so an unrecognised type is a plain
    /// decoding error rather than a tolerated skip.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let type = try container.decode(String.self)
        switch type {
        case "EVENT":
            self = try .event(container.decode(NostrEvent.self))
        case "AUTH":
            self = try .auth(container.decode(NostrEvent.self))
        case "CLOSE":
            self = try .close(subscriptionID: container.decode(String.self))
        case "REQ":
            let subscriptionID = try container.decode(String.self)
            var filters: [Filter] = []
            while !container.isAtEnd {
                try filters.append(container.decode(Filter.self))
            }
            self = .req(subscriptionID: subscriptionID, filters: filters)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unrecognised client message type \"\(type)\""
                )
            )
        }
    }
}
