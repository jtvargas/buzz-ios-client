import Foundation
import NostrCore

/// The narrow durable-storage capability the importer needs, behind a seam so its
/// success path can be tested without the device Keychain (which is unavailable on
/// headless CI). ``PairedCommunityKeyStore`` is the production conformer.
///
/// The relay travels with the key because the destination is not known before the payload
/// is parsed: a credential names its own relay, and the community it belongs to may be one
/// this device does not have yet. This used to be `store(_:)` against the app's single
/// signer, which is exactly the assumption multi-community had to remove — a pairing for
/// another relay would otherwise overwrite the identity of the community on screen.
protocol PairedKeyStoring: Sendable {
    /// Commits `key` as the identity for the community at `relayURLString`, creating that
    /// community if the device does not have it. `false` if it could not be committed,
    /// which is the one thing that must stop a pairing acknowledging.
    func storePairedKey(_ key: PrivateKey, forRelay relayURLString: String) async -> Bool
}

/// Parses and durably imports the Buzz credential a desktop pairing session
/// delivers as a NIP-AB `custom` payload — `{relayUrl, pubkey, nsec}` JSON.
///
/// This is the app-specific gate the generic ``TargetPairingSession`` defers to. It
/// enforces every hardening rule the transport itself cannot: `payloadType ==
/// "custom"`, that the decoded `nsec` derives *exactly* the advertised `pubkey`
/// (never trusting the payload's own pubkey), and a valid relay. It returns `true`
/// only once the key is committed to the Keychain — the durable-import signal that
/// alone lets the session answer `complete(true)`.
///
/// The `nsec` is decoded into a `PrivateKey` and handed straight to the signer;
/// this type never retains the secret.
struct PairingCredentialImporter: PairingPayloadHandler {
    let keyStore: any PairedKeyStoring

    func importPayload(payloadType: String, payload: String) async -> Bool {
        // Only Buzz's `custom` credential shape is accepted (never nsec/bunker/…).
        guard payloadType == "custom" else { return false }
        guard let credential = PairedCredential(json: payload) else { return false }

        // The decoded nsec must derive the advertised pubkey — a self-consistency
        // check that catches a tampered or mismatched credential.
        guard let key = try? PrivateKey(nsec: credential.nsec) else { return false }
        guard key.publicKey.hex == credential.pubkey.lowercased() else { return false }

        // The relay arrives as the desktop's HTTP API base; convert it to the socket
        // URL the engine connects on, rejecting anything unusable.
        guard let websocketURLString = RelayEndpoint.websocketURLString(fromAnyRelay: credential.relayUrl) else {
            return false
        }

        // Durable, atomic Keychain commit — the point at which the transfer is
        // considered complete (NIP-AB Step 5). The relay goes with it: which community
        // this key belongs to is the store's decision, not this type's.
        return await keyStore.storePairedKey(key, forRelay: websocketURLString)
    }
}

/// The Buzz pairing credential carried in a `custom` payload.
///
/// The desktop sends `{"relayUrl": <http base>, "pubkey": <hex>, "nsec": <bech32>}`.
/// Parsing is total and non-throwing: a malformed or partial credential yields
/// `nil`, which the importer treats as a failed import.
struct PairedCredential: Equatable {
    let relayUrl: String
    let pubkey: String
    let nsec: String

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { return nil }
        relayUrl = raw.relayUrl
        pubkey = raw.pubkey
        nsec = raw.nsec
    }

    init(relayUrl: String, pubkey: String, nsec: String) {
        self.relayUrl = relayUrl
        self.pubkey = pubkey
        self.nsec = nsec
    }

    private struct Raw: Decodable {
        let relayUrl: String
        let pubkey: String
        let nsec: String
    }
}
