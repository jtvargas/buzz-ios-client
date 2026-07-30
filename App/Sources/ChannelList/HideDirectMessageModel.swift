import BuzzKit
import NostrCore
import Observation

/// What the app needs from the engine to hide a direct message.
///
/// A protocol for the same reason ``DirectMessageOpening`` is one: the substance of a hide
/// is the states *around* the call — in flight, refused — and a stub is how those are
/// asserted without a relay. Not main-actor isolated, because `SyncEngine` is an actor and
/// an actor cannot conform to a globally isolated protocol.
protocol DirectMessageHiding: Sendable {
    /// Hides the direct message `channelID` from this identity's own sidebar.
    func hideDirectMessage(_ channelID: String) async throws
}

extension SyncEngine: DirectMessageHiding {}

/// Turns "hide this conversation" into a relay command, and holds what came back.
///
/// # Why this is a model and not a button action
///
/// Two reasons, both of which a `Task {}` in the row would get wrong. The first is that
/// the row is *about to disappear*: a successful hide takes its own conversation out of
/// the list, so there is nowhere in that row's lifetime to report a failure from. The
/// second is the second press — a context menu can be opened again on a row whose hide is
/// still on the wire, and two commands would be two events for one intent.
///
/// A hide is idempotent relay-side, so unlike ``CreateChannelModel`` the guard is not
/// protecting against a duplicate *thing* being made. It is protecting the reader from a
/// second refusal alert for one press.
@MainActor
@Observable
final class HideDirectMessageModel {
    /// The conversations whose hides are in flight, so a second press on the *same* row is
    /// ignored rather than queued.
    ///
    /// A set and not one id, for the reason ``DirectMessageRouter/openingPeers`` is one:
    /// a single slot would make every *other* row's Hide dead until the first answered.
    private(set) var hidingChannels: Set<String> = []
    /// A failed hide, in words, for the surface that shows it. Cleared when acknowledged,
    /// and on the next success.
    var failure: String?

    private let hider: any DirectMessageHiding

    init(hider: any DirectMessageHiding) {
        self.hider = hider
    }

    /// Whether this conversation's own hide is in flight, which is what a per-row control
    /// asks.
    func isHiding(_ channelID: String) -> Bool { hidingChannels.contains(channelID) }

    /// Starts the hide. Fire-and-forget by design: the caller is a menu item on a row that
    /// is about to leave the list, so there is nothing left to await it.
    func hide(_ channelID: String) {
        guard hidingChannels.insert(channelID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await hider.hideDirectMessage(channelID)
                hidingChannels.remove(channelID)
                // Cleared on success and not only when acknowledged, so an unacknowledged
                // refusal from an earlier attempt cannot surface as an alert over whatever
                // screen happens to be up when a later hide succeeds.
                failure = nil
            } catch {
                hidingChannels.remove(channelID)
                failure = Self.message(for: error)
            }
        }
    }

    /// The reader-facing sentence for a failed hide.
    ///
    /// The relay's own words survive for the reasons it states in prose, because the two
    /// most likely refusals here are both prose: `forbidden: not a member of this DM`
    /// carries no NIP-01 prefix at all and classifies as ``OKReason/unspecified(_:)``, and
    /// `invalid: channel is not a DM` is what a two-person *channel* earns — the sidebar
    /// calls a conversation direct when its roster is two people, and only the relay knows
    /// whether it is really a DM. Summarising either into "could not hide" would throw away
    /// the only part that explains anything.
    static func message(for error: any Error) -> String {
        guard let error = error as? DirectMessageError else {
            return "Could not hide the conversation. Try again."
        }
        switch error {
        case let .rejected(reason):
            return message(for: reason)
        case .publishFailed:
            return "No connection to the relay. Try again once it reconnects."
        case .invalidPeerPubkey, .duplicateEventIDUnresolved, .malformedResponse:
            // Reachable only through the open command, which parses a payload and
            // normalises a pubkey; a hide does neither.
            return "Could not hide the conversation. Try again."
        }
    }

    private static func message(for reason: OKReason) -> String {
        switch reason {
        case .restricted:
            return "The relay would not hide this conversation for you."
        case .rateLimited:
            return "The relay is rate limiting. Wait a moment and try again."
        case let .invalid(message), let .unspecified(message):
            return message.isEmpty
                ? "The relay refused to hide it."
                : "The relay refused to hide it: \(message)"
        case .duplicate, .pow, .authRequired, .blocked, .error:
            return "The relay refused to hide it."
        }
    }
}
