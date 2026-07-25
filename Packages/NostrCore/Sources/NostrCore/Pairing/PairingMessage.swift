import Foundation

/// A decrypted NIP-AB pairing message — the JSON that rides inside a `kind:24134`
/// event's NIP-44 ciphertext.
///
/// Every pairing event carries exactly one of these. The `type` field discriminates
/// them on the wire; unknown fields on a known type are ignored, and an unknown
/// `type` fails to decode (the session then treats it as out-of-order and discards
/// it silently, never revealing the parse failure to the relay).
public enum PairingMessage: Sendable, Equatable {
    /// _target_ → _source_: proves possession of the QR secret and advertises the
    /// target's ephemeral key (the event's `pubkey`).
    case offer(version: Int, sessionID: String)
    /// _source_ → _target_: commits the source to the session transcript.
    case sasConfirm(transcriptHash: String)
    /// _source_ → _target_: the encrypted secret. `payloadType` namespaces the
    /// `payload` string (`nsec`, `bunker`, `connect`, or `custom`).
    case payload(payloadType: String, payload: String)
    /// _target_ → _source_: advisory acknowledgement that import succeeded (`true`)
    /// or failed after decryption (`false`).
    case complete(success: Bool)
    /// Either direction: terminate with a reason (see ``PairingAbortReason``).
    case abort(reason: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case sessionID = "session_id"
        case transcriptHash = "transcript_hash"
        case payloadType = "payload_type"
        case payload
        case success
        case reason
    }

    private enum Discriminator: String {
        case offer
        case sasConfirm = "sas-confirm"
        case payload
        case complete
        case abort
    }
}

// MARK: - Codable

extension PairingMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let discriminator = Discriminator(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown pairing message type \"\(raw)\""
            )
        }
        switch discriminator {
        case .offer:
            self = try .offer(
                version: container.decode(Int.self, forKey: .version),
                sessionID: container.decode(String.self, forKey: .sessionID)
            )
        case .sasConfirm:
            self = try .sasConfirm(transcriptHash: container.decode(String.self, forKey: .transcriptHash))
        case .payload:
            self = try .payload(
                payloadType: container.decode(String.self, forKey: .payloadType),
                payload: container.decode(String.self, forKey: .payload)
            )
        case .complete:
            self = try .complete(success: container.decode(Bool.self, forKey: .success))
        case .abort:
            self = try .abort(reason: container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .offer(version, sessionID):
            try container.encode(Discriminator.offer.rawValue, forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(sessionID, forKey: .sessionID)
        case let .sasConfirm(transcriptHash):
            try container.encode(Discriminator.sasConfirm.rawValue, forKey: .type)
            try container.encode(transcriptHash, forKey: .transcriptHash)
        case let .payload(payloadType, payload):
            try container.encode(Discriminator.payload.rawValue, forKey: .type)
            try container.encode(payloadType, forKey: .payloadType)
            try container.encode(payload, forKey: .payload)
        case let .complete(success):
            try container.encode(Discriminator.complete.rawValue, forKey: .type)
            try container.encode(success, forKey: .success)
        case let .abort(reason):
            try container.encode(Discriminator.abort.rawValue, forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - JSON

public extension PairingMessage {
    /// The compact UTF-8 JSON string that becomes the event's NIP-44 plaintext.
    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NostrPairError.internalError("pairing message did not encode to UTF-8")
        }
        return string
    }

    /// Parses a decrypted plaintext JSON string into a message, or throws if it is
    /// not a recognised pairing message.
    static func decode(json: String) throws -> PairingMessage {
        try JSONDecoder().decode(PairingMessage.self, from: Data(json.utf8))
    }
}
