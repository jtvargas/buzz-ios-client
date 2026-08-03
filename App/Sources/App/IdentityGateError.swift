import Foundation

/// A reason the identity gate could not proceed, phrased for display.
enum IdentityGateError: Equatable {
    case invalidRelayURL
    case invalidSecretKey
    /// The key could not be committed to the Keychain. Its own case because the reader is
    /// otherwise told "couldn't connect" about a failure that never reached the network —
    /// which sends them to check a relay URL that was fine.
    case couldNotStoreKey
    /// The address is a real community and it is reachable — it just will not have this
    /// key. Its own case because "couldn't connect" sends a reader to check their typing
    /// and their signal, and neither is wrong: nothing they can do to the address gets
    /// them in, and the thing that does is a link somebody else has to send them.
    case needsInvitation
    case couldNotStart(String)

    var message: String {
        switch self {
        case .invalidRelayURL:
            "Enter a relay address, like wss://relay.example — or the https:// address it serves its pages on."
        case .invalidSecretKey:
            "That doesn't look like a valid nsec key."
        case .couldNotStoreKey:
            "Couldn't save the key on this device. Check that Hive has Keychain access, then try again."
        case .needsInvitation:
            "This community is invite-only. Ask someone already in it for an invite link, then open "
                + "that link to join — its address alone won't let a new key in."
        case let .couldNotStart(detail):
            "Couldn't connect: \(detail)"
        }
    }
}
