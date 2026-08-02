import Foundation

/// A reason the identity gate could not proceed, phrased for display.
enum IdentityGateError: Equatable {
    case invalidRelayURL
    case invalidSecretKey
    /// The key could not be committed to the Keychain. Its own case because the reader is
    /// otherwise told "couldn't connect" about a failure that never reached the network —
    /// which sends them to check a relay URL that was fine.
    case couldNotStoreKey
    case couldNotStart(String)

    var message: String {
        switch self {
        case .invalidRelayURL:
            "Enter a relay address, like wss://relay.example — or the https:// address it serves its pages on."
        case .invalidSecretKey:
            "That doesn't look like a valid nsec key."
        case .couldNotStoreKey:
            "Couldn't save the key on this device. Check that Hive has Keychain access, then try again."
        case let .couldNotStart(detail):
            "Couldn't connect: \(detail)"
        }
    }
}
