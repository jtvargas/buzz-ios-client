import CryptoKit
import Foundation

/// NIP-OA owner attestation: the `auth` tag by which an owner key authorizes an
/// agent key to publish events under the agent's own authorship.
///
/// This layer verifies attestations; it does not issue them. Verification lets a
/// client render provenance ("authorized by …") once it has established that a
/// claimed owner really signed the authorization. The credential never overrides
/// authorship — the event stays authored by `event.pubkey`.
///
/// The credential is a four-element tag:
///
///     ["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
///
/// The owner's signature covers `SHA-256` of the UTF-8 preimage
/// `nostr:agent-auth:<event.pubkey>:<conditions>`. The `<conditions>` string is
/// part of the signed preimage and is used exactly as it appears on the tag; it
/// is never reordered, normalized, or canonicalized before hashing.
public enum NIPOA {
    private static let domainSeparator = "nostr:agent-auth:"
    private static let ownerPubkeyHexLength = 64
    private static let signatureHexLength = 128

    /// The single `auth` tag among an event's tags, or `nil` when none is
    /// present or when more than one appears.
    ///
    /// NIP-OA treats an event carrying multiple `auth` tags as having no valid
    /// attestation, so ambiguity resolves to "absent" rather than to a guess.
    public static func authTag(in tags: [[String]]) -> [String]? {
        var found: [String]?
        for tag in tags where tag.first == "auth" {
            guard found == nil else { return nil }
            found = tag
        }
        return found
    }

    /// Verifies an owner attestation against the agent (event) pubkey it claims
    /// to authorize.
    ///
    /// Returns `false` when the tag is not exactly four elements, when the owner
    /// pubkey is not valid 32-byte lowercase hex, when the owner pubkey equals
    /// the event pubkey (self-attestation, which the spec forbids), when the
    /// signature is not valid 64-byte hex, or when the BIP-340 signature does
    /// not verify over the preimage hash.
    public static func verify(authTag tag: [String], eventPubkey: String) -> Bool {
        guard tag.count == 4, tag[0] == "auth" else { return false }
        let ownerPubkeyHex = tag[1]
        let conditions = tag[2]
        let signatureHex = tag[3]

        guard ownerPubkeyHex.count == ownerPubkeyHexLength,
              signatureHex.count == signatureHexLength,
              ownerPubkeyHex != eventPubkey,
              let ownerKey = Data(hexString: ownerPubkeyHex),
              let signature = Data(hexString: signatureHex)
        else { return false }

        let preimage = Data((domainSeparator + eventPubkey + ":" + conditions).utf8)
        let message = Data(SHA256.hash(data: preimage))
        return verifySchnorrSignature(signature: signature, message: message, publicKeyXOnly: ownerKey)
    }

    /// The verified owner pubkey attested for an event, or `nil` when the event
    /// carries no valid attestation.
    ///
    /// The event must itself be authentic — a valid `auth` tag on an invalid
    /// event establishes nothing — so this gates on `NostrEvent.isValid` before
    /// checking the owner signature.
    public static func verifiedOwnerPubkey(of event: NostrEvent) -> String? {
        guard event.isValid, let tag = authTag(in: event.tags) else { return nil }
        return verify(authTag: tag, eventPubkey: event.pubkey) ? tag[1] : nil
    }
}
