import Foundation

/// The client-chosen identifier for a live subscription.
///
/// A relay echoes this token back on every `EVENT`, `EOSE`, and `CLOSED` it
/// sends for the subscription, so it is how the ``SubscriptionManager`` routes an
/// inbound frame to the sink that asked for it. Wrapping the raw string in a type
/// keeps a subscription id from being confused with any other string on the wire
/// — an event id, a group id, a pubkey — at the call sites that pass them around.
///
/// Ids are minted by the manager and carry an `s` prefix, which keeps them
/// disjoint from the `q`-prefixed ids ``RelayConnection`` mints for one-shot
/// queries: the two id spaces share one socket, and a collision would cross a
/// live subscription's frames with a query's.
public struct SubscriptionID: Hashable, Sendable, CustomStringConvertible {
    /// The token as it travels on the wire.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}
