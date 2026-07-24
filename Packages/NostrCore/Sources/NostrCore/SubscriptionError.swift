import Foundation

/// Why a live subscription could not be opened, or why it ended.
///
/// The two pre-send cases are caught by the ``SubscriptionManager`` before a
/// `REQ` ever reaches the wire, turning a filter a Buzz relay would silently
/// refuse into a thrown error at the call site that built it. The third carries a
/// relay's own `CLOSED` verdict, already classified through ``OKReason``, to the
/// sink so the store can react to a subscription the relay took away.
public enum SubscriptionError: Error, Equatable, Sendable {
    /// A filter carried no `kinds`. A Buzz relay rejects an unbounded, kindless
    /// subscription rather than serve every event it holds, so the manager
    /// refuses to send one.
    case kindlessFilter

    /// A filter asked for a pubkey-gated kind without scoping it to the
    /// authenticated identity. The relay serves those kinds only when the `#p`
    /// query names exactly the authenticated user; any other `#p` set — empty,
    /// foreign, or mixed — would be refused. Carries the offending kind.
    case pubkeyScopeRequired(EventKind)

    /// The relay closed the subscription. The reason is the classified `CLOSED`
    /// message; a terminal reason means the subscription will not be re-opened.
    case closedByRelay(OKReason)
}
