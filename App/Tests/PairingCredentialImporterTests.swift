import Foundation
@testable import Hive
import NostrCore
import Testing

/// The app-specific pairing payload gate: `custom`-only, nsec→pubkey equality,
/// relay conversion, and the atomic durable commit — validated off-Keychain via a
/// recording key store.
@Suite struct PairingCredentialImporterTests {
    static let targetPriv = "3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b3c5d7e9f1a3b5c7d9e1f3a5b"

    private func credentialJSON(relayUrl: String, pubkey: String, nsec: String) -> String {
        // Values here are hex/bech32/URL fixtures with no characters needing escaping.
        #"{"relayUrl":"\#(relayUrl)","pubkey":"\#(pubkey)","nsec":"\#(nsec)"}"#
    }

    private func key() throws -> PrivateKey { try PrivateKey(hex: Self.targetPriv) }

    // MARK: - Rejections (never touch the store)

    @Test func rejectsNonCustomPayloadType() async throws {
        let store = RecordingKeyStore()
        let importer = PairingCredentialImporter(keyStore: store)
        let key = try key()
        let json = credentialJSON(relayUrl: "http://host:3004", pubkey: key.publicKey.hex, nsec: key.nsec)
        #expect(await importer.importPayload(payloadType: "nsec", payload: json) == false)
        #expect(store.stored.isEmpty)
    }

    @Test func rejectsMismatchedPubkey() async throws {
        let store = RecordingKeyStore()
        let importer = PairingCredentialImporter(keyStore: store)
        let key = try key()
        // A pubkey that the nsec does not derive.
        let wrongPubkey = "199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a"
        let json = credentialJSON(relayUrl: "http://host:3004", pubkey: wrongPubkey, nsec: key.nsec)
        #expect(await importer.importPayload(payloadType: "custom", payload: json) == false)
        #expect(store.stored.isEmpty)
    }

    @Test func rejectsBadRelay() async throws {
        let store = RecordingKeyStore()
        let importer = PairingCredentialImporter(keyStore: store)
        let key = try key()
        let json = credentialJSON(relayUrl: "ftp://host", pubkey: key.publicKey.hex, nsec: key.nsec)
        #expect(await importer.importPayload(payloadType: "custom", payload: json) == false)
        #expect(store.stored.isEmpty)
    }

    @Test func rejectsMalformedJSON() async {
        let store = RecordingKeyStore()
        let importer = PairingCredentialImporter(keyStore: store)
        #expect(await importer.importPayload(payloadType: "custom", payload: "not json") == false)
        #expect(store.stored.isEmpty)
    }

    @Test func reportsStorageFailure() async throws {
        let store = RecordingKeyStore(shouldFail: true)
        let importer = PairingCredentialImporter(keyStore: store)
        let key = try key()
        let json = credentialJSON(relayUrl: "http://host:3004", pubkey: key.publicKey.hex, nsec: key.nsec)
        #expect(await importer.importPayload(payloadType: "custom", payload: json) == false)
    }

    // MARK: - Success (atomic commit + relay conversion)

    @Test func importsValidCredentialAndPersistsRelay() async throws {
        let previousRelay = RelayEndpoint.storedURLString
        defer { RelayEndpoint.storedURLString = previousRelay }

        let store = RecordingKeyStore()
        let importer = PairingCredentialImporter(keyStore: store)
        let key = try key()
        let json = credentialJSON(relayUrl: "http://100.111.202.55:3004", pubkey: key.publicKey.hex, nsec: key.nsec)

        #expect(await importer.importPayload(payloadType: "custom", payload: json) == true)
        #expect(store.stored.map { $0.publicKey.hex } == [key.publicKey.hex])
        // The desktop's HTTP base was converted to the socket URL the engine uses.
        #expect(RelayEndpoint.storedURLString == "ws://100.111.202.55:3004")
    }
}

/// Parsing of the `{relayUrl, pubkey, nsec}` credential JSON.
@Suite struct PairedCredentialTests {
    @Test func parsesWellFormedCredential() {
        let json = #"{"relayUrl":"http://host:3004","pubkey":"abcd","nsec":"nsec1xyz"}"#
        let credential = PairedCredential(json: json)
        #expect(credential == PairedCredential(relayUrl: "http://host:3004", pubkey: "abcd", nsec: "nsec1xyz"))
    }

    @Test func rejectsMissingFields() {
        #expect(PairedCredential(json: #"{"relayUrl":"http://host","pubkey":"abcd"}"#) == nil)
    }

    @Test func rejectsNonObject() {
        #expect(PairedCredential(json: "[]") == nil)
    }
}

/// The HTTP-base → WebSocket conversion the pairing payload requires.
@Suite struct RelayEndpointConversionTests {
    @Test func convertsHTTPBaseToWebSocket() {
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "http://host:3004") == "ws://host:3004")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "https://relay.example") == "wss://relay.example")
    }

    @Test func passesWebSocketURLThrough() {
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "ws://host:3004") == "ws://host:3004")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "wss://relay.example") == "wss://relay.example")
    }

    @Test func rejectsUnsupportedScheme() {
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "ftp://host") == nil)
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "garbage") == nil)
    }
}
