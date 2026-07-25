import Foundation
import NostrCore

/// The narrow durable-storage capability the importer needs, behind a seam so its
/// success path can be tested without the device Keychain (which is unavailable on
/// headless CI). ``KeychainSigner`` is the production conformer.
protocol PairedKeyStoring: Sendable {
    func store(_ key: PrivateKey) throws
}

extension KeychainSigner: PairedKeyStoring {}

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
        // considered complete (NIP-AB Step 5).
        do {
            try keyStore.store(key)
        } catch {
            return false
        }
        RelayEndpoint.storedURLString = websocketURLString
        return true
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
