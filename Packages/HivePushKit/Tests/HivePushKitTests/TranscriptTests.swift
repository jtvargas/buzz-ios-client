import CryptoKit
import Foundation
@testable import HivePushKit
import Testing

/// Known-answer vectors from the gateway's
/// `tests/vectors/app_attest_transcripts.json`. Client canonical encoders must
/// reproduce `transcript` byte-for-byte; `sha256` is the hex digest of those
/// UTF-8 bytes.
@Suite("App Attest transcript encoding", .timeLimit(.minutes(1)))
struct TranscriptTests {

    // MARK: - Shared vector inputs

    private static let challengeID = "11111111-1111-4111-8111-111111111111"
    private static let installationHandle = "22222222-2222-4222-8222-222222222222"
    private static let challenge = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private static let keyID = "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="
    private static let appProfile = "buzz-ios-dogfood"
    private static let endpoint =
        "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    private static let relayPubkey =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let notBefore: Int64 = 1_752_620_000
    private static let expiresAt: Int64 = 1_752_624_000

    // MARK: - Enrollment

    @Test("Enrollment transcript matches gateway test vector")
    func enrollTranscript() {
        let transcript = EnrollTranscript(
            v: 1,
            audience: NIPPLAudience.installations,
            challengeID: Self.challengeID,
            challenge: Self.challenge,
            keyID: Self.keyID,
            appProfile: Self.appProfile,
            endpoint: Self.endpoint,
            endpointEpoch: 1,
            expiresAt: Self.expiresAt
        )

        let json = transcript.canonicalJSON()
        let fullTranscript = "buzz.push.enroll.v1\n" + String(data: json, encoding: .utf8)!

        let expectedTranscript = """
            buzz.push.enroll.v1
            {"v":1,"audience":"https://push.buzz.xyz/v1/installations",\
            "challenge_id":"11111111-1111-4111-8111-111111111111",\
            "challenge":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",\
            "key_id":"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo=",\
            "app_profile":"buzz-ios-dogfood",\
            "endpoint":"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",\
            "endpoint_epoch":1,"expires_at":1752624000}
            """

        #expect(fullTranscript == expectedTranscript)

        let hash = SHA256.hash(data: Data(fullTranscript.utf8))
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "58274bd9e9a86489fe5bae36aecbe89618824433189405ff4de8b18b58384270")
    }

    @Test("Enrollment clientDataHash matches gateway SHA-256")
    func enrollClientDataHash() {
        let transcript = EnrollTranscript(
            v: 1,
            audience: NIPPLAudience.installations,
            challengeID: Self.challengeID,
            challenge: Self.challenge,
            keyID: Self.keyID,
            appProfile: Self.appProfile,
            endpoint: Self.endpoint,
            endpointEpoch: 1,
            expiresAt: Self.expiresAt
        )

        let hash = AppAttestClientData.enrollHash(transcript: transcript)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "58274bd9e9a86489fe5bae36aecbe89618824433189405ff4de8b18b58384270")
    }

    // MARK: - Delegation

    @Test("Delegation transcript matches gateway test vector")
    func delegateTranscript() {
        let transcript = DelegateTranscript(
            v: 1,
            audience: NIPPLAudience.delegations,
            challengeID: Self.challengeID,
            challenge: Self.challenge,
            installationHandle: Self.installationHandle,
            endpointEpoch: 1,
            generation: 1,
            relayPubkey: Self.relayPubkey,
            notBefore: Self.notBefore,
            expiresAt: Self.expiresAt
        )

        let json = transcript.canonicalJSON()
        let fullTranscript = "buzz.push.delegate.v1\n" + String(data: json, encoding: .utf8)!

        let expectedTranscript = """
            buzz.push.delegate.v1
            {"v":1,"audience":"https://push.buzz.xyz/v1/delegations",\
            "challenge_id":"11111111-1111-4111-8111-111111111111",\
            "challenge":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",\
            "installation_handle":"22222222-2222-4222-8222-222222222222",\
            "endpoint_epoch":1,"generation":1,\
            "relay_pubkey":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\
            "not_before":1752620000,"expires_at":1752624000}
            """

        #expect(fullTranscript == expectedTranscript)

        let hash = SHA256.hash(data: Data(fullTranscript.utf8))
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "7466177cc2dc2a4f9a075fdbb461531692fc858778a171a5862b855cccfaa059")
    }

    @Test("Delegation clientDataHash matches gateway SHA-256")
    func delegateClientDataHash() {
        let transcript = DelegateTranscript(
            v: 1,
            audience: NIPPLAudience.delegations,
            challengeID: Self.challengeID,
            challenge: Self.challenge,
            installationHandle: Self.installationHandle,
            endpointEpoch: 1,
            generation: 1,
            relayPubkey: Self.relayPubkey,
            notBefore: Self.notBefore,
            expiresAt: Self.expiresAt
        )

        let hash = AppAttestClientData.delegateHash(transcript: transcript)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "7466177cc2dc2a4f9a075fdbb461531692fc858778a171a5862b855cccfaa059")
    }

    // MARK: - Installation revocation

    @Test("Revoke-installation transcript matches gateway test vector")
    func revokeInstallationTranscript() {
        let transcript = RevokeInstallationTranscript(
            v: 1,
            audience: NIPPLAudience.revokeInstallation,
            challengeID: Self.challengeID,
            challenge: Self.challenge,
            installationHandle: Self.installationHandle,
            endpointEpoch: 1,
            newEndpointEpoch: 2
        )

        let json = transcript.canonicalJSON()
        let fullTranscript = "buzz.push.revoke-installation.v1\n" + String(data: json, encoding: .utf8)!

        let expectedTranscript = """
            buzz.push.revoke-installation.v1
            {"v":1,"audience":"https://push.buzz.xyz/v1/installations/revoke",\
            "challenge_id":"11111111-1111-4111-8111-111111111111",\
            "challenge":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",\
            "installation_handle":"22222222-2222-4222-8222-222222222222",\
            "endpoint_epoch":1,"new_endpoint_epoch":2}
            """

        #expect(fullTranscript == expectedTranscript)

        let hash = SHA256.hash(data: Data(fullTranscript.utf8))
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "0ba51827af6586a5e1230e9b770b99544fb342efb55db3ab1ce499cf24a893c8")
    }

    @Test("Revoke-installation clientDataHash matches gateway SHA-256")
    func revokeInstallationClientDataHash() {
        let transcript = RevokeInstallationTranscript(
            v: 1,
            audience: NIPPLAudience.revokeInstallation,
            challengeID: Self.challengeID,
            challenge: Self.challenge,
            installationHandle: Self.installationHandle,
            endpointEpoch: 1,
            newEndpointEpoch: 2
        )

        let hash = AppAttestClientData.revokeInstallationHash(transcript: transcript)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "0ba51827af6586a5e1230e9b770b99544fb342efb55db3ab1ce499cf24a893c8")
    }
}
