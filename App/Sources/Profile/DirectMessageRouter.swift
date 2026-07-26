import BuzzKit
import Observation
import SwiftUI

/// What the app needs from the engine to start a direct message.
///
/// A protocol rather than a `SyncEngine` reference so the router is testable without a
/// relay: the whole point of the router is the *states around* the call — in flight,
/// failed, ready to navigate — and those are what a stub can exercise.
///
/// Deliberately *not* main-actor isolated: `SyncEngine` is an actor, and an actor cannot
/// conform to a globally isolated protocol. An `async` requirement is satisfied from
/// either isolation, which is all the router needs.
protocol DirectMessageOpening: Sendable {
    /// Opens the existing direct message with `peer`, or creates it, returning the
    /// channel id either way.
    func openDirectMessage(with peer: String) async throws -> String
}

extension SyncEngine: DirectMessageOpening {}

/// Turns "message this person" into a channel the app can navigate to.
///
/// # Why this is a router and not a button action
///
/// Opening a DM is a round trip to the relay, and the tap that starts it happens inside
/// a sheet that closes immediately — so there is nowhere in the sheet's own lifetime to
/// hold the in-flight state, and nothing there to navigate with either. The router
/// outlives the sheet: the sheet asks it to open, the sheet goes away, and the
/// navigation surface picks the result up.
///
/// The relay makes open-and-create one idempotent call keyed on the participant pair,
/// so there is deliberately no "does a DM already exist" lookup here — asking twice is
/// the same as asking once, and a client-side existence check would be a second, weaker
/// answer to a question the relay already answers exactly.
@MainActor
@Observable
final class DirectMessageRouter {
    /// The channel to navigate to, once. Whoever consumes it clears it — leaving it set
    /// would re-push the same conversation on the next unrelated body pass.
    var pendingChannelID: String?
    /// The peer whose open is in flight, so a sheet or row can show progress and a
    /// second tap on the same person is ignored rather than queued.
    private(set) var openingPeer: String?
    /// A failed open, for the surface that shows it. Cleared when acknowledged.
    var failure: String?

    private let opener: any DirectMessageOpening

    init(opener: any DirectMessageOpening) {
        self.opener = opener
    }

    var isOpening: Bool { openingPeer != nil }

    /// Starts the open. Fire-and-forget by design: the caller is a button in a sheet
    /// that is already dismissing, so there is nothing left to await it.
    func open(with peer: String) {
        guard openingPeer == nil else { return }
        openingPeer = peer
        Task { [weak self] in
            guard let self else { return }
            do {
                let channelID = try await opener.openDirectMessage(with: peer)
                openingPeer = nil
                pendingChannelID = channelID
            } catch {
                openingPeer = nil
                failure = Self.message(for: error)
            }
        }
    }

    /// The reader-facing sentence for a failed open.
    ///
    /// Mapped from the typed error rather than printed: `DirectMessageError` exists so
    /// the UI can say something true about *why*, and "restricted" in particular is not
    /// a transient failure the reader should retry into.
    static func message(for error: any Error) -> String {
        guard let error = error as? DirectMessageError else {
            return "Could not start the conversation. Try again."
        }
        switch error {
        case .invalidPeerPubkey:
            return "That identity is not a valid key, so there is nobody to message."
        case let .rejected(reason):
            switch reason {
            case .restricted:
                return "The relay would not open this conversation for you."
            case .rateLimited:
                return "The relay is rate limiting. Wait a moment and try again."
            default:
                return "The relay refused to open the conversation."
            }
        case .duplicateEventIDUnresolved:
            return "The conversation could not be opened. Try again."
        case .malformedResponse:
            return "The relay answered in a form this app does not understand."
        case .publishFailed:
            return "No connection to the relay. Try again once it reconnects."
        }
    }
}

extension EnvironmentValues {
    /// The app's DM router, injected beside the navigation surface that consumes its
    /// result. Optional, and `nil` by default, because an environment default is
    /// constructed off the main actor and this type is main-actor isolated — the same
    /// reason ``RelativeTimeTicker`` is optional here. A surface without one simply
    /// offers no Message action.
    @Entry var directMessageRouter: DirectMessageRouter?
}
