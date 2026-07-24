import CryptoKit
import Foundation

/// A signed Nostr event in its NIP-01 wire form.
///
/// The type is immutable: an event's id is a hash over its own fields and its
/// signature covers that id, so mutating any field afterwards would invalidate
/// both. Instances arrive by decoding the wire or are constructed whole; there
/// is no mutating surface.
public struct NostrEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pubkey: String
    public let createdAt: Int64
    public let kind: EventKind
    public let tags: [[String]]
    public let content: String
    public let sig: String

    private enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content, sig
        case createdAt = "created_at"
    }

    public init(
        id: String,
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String,
        sig: String
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    // MARK: - Identity

    /// The NIP-01 event id for a set of fields: SHA-256 over the canonical
    /// serialization. Returns raw digest bytes; callers hex-encode for the wire.
    public static func computeID(
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String
    ) -> Data {
        let canonical = CanonicalJSON.serialize(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        return Data(SHA256.hash(data: canonical))
    }

    // MARK: - Validation

    /// Whether the claimed id is the hash of the event's own fields.
    public var hasValidID: Bool {
        let recomputed = Self.computeID(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        return recomputed.hexString == id
    }

    /// Whether the event is fully authentic: the id hashes its fields **and**
    /// the signature verifies against the claimed author over that id.
    ///
    /// Both checks are required. Verifying only the signature would let a relay
    /// swap an event's content while keeping a signature that still verifies
    /// over the original id; recomputing the id closes that gap. Verifying only
    /// the id would accept a forged event whose fields merely hash consistently
    /// but that its claimed author never signed.
    public var isValid: Bool {
        guard hasValidID,
              let publicKey = Data(hexString: pubkey), publicKey.count == 32,
              let signature = Data(hexString: sig),
              let message = Data(hexString: id)
        else { return false }
        return verifySchnorrSignature(signature: signature, message: message, publicKeyXOnly: publicKey)
    }

    // MARK: - Tag access

    /// The value at index 1 of the first tag named `name` — the common
    /// single-value case.
    public func firstValue(forTag name: String) -> String? {
        for tag in tags where tag.count >= 2 && tag[0] == name {
            return tag[1]
        }
        return nil
    }

    /// Every index-1 value across all tags named `name`, in document order.
    public func allValues(forTag name: String) -> [String] {
        tags.compactMap { tag in
            tag.count >= 2 && tag[0] == name ? tag[1] : nil
        }
    }

    public var referencedEventIDs: [String] {
        allValues(forTag: "e")
    }

    public var referencedPubkeys: [String] {
        allValues(forTag: "p")
    }

    /// The NIP-29 group (`h` tag) this event is scoped to, if any.
    public var groupID: String? {
        firstValue(forTag: "h")
    }

    /// The `d` identifier of an addressable event, if present.
    public var addressableIdentifier: String? {
        firstValue(forTag: "d")
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    // MARK: - Threading (NIP-10 marked tags)

    /// Where this event sits in a thread, resolved from its marked `e` tags.
    ///
    /// An event counts as a reply only when it carries an `e` tag explicitly
    /// marked `reply`; a lone `root` marker does not make it one. When several
    /// `reply` markers are present the last wins. A direct reply to a thread's
    /// opener carries no distinct `root`, so the parent doubles as the root.
    /// These rules mirror Buzz's own threading resolver, so both clients agree
    /// on the shape of a conversation instead of one threading messages the
    /// other shows flat.
    public var threadReference: ThreadReference {
        let eventTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        guard let replyTag = eventTags.last(where: { $0.count >= 4 && $0[3] == "reply" }) else {
            return ThreadReference(parentID: nil, rootID: nil)
        }
        let parentID = replyTag[1]
        let rootID = eventTags.first { $0.count >= 4 && $0[3] == "root" }?[1]
        return ThreadReference(parentID: parentID, rootID: rootID ?? parentID)
    }

    /// Whether the author chose to echo this reply into the channel as well as
    /// the thread. Buzz marks such events with a `broadcast=1` tag, and they
    /// belong in both places.
    public var isBroadcastReply: Bool {
        tags.contains { $0.count >= 2 && $0[0] == "broadcast" && $0[1] == "1" }
    }

    /// Whether this event belongs only inside a thread and so must not surface
    /// as a standalone message in the channel.
    public var isThreadReply: Bool {
        threadReference.isReply && !isBroadcastReply
    }
}

/// An event's resolved position within a thread.
public struct ThreadReference: Sendable, Equatable {
    /// The event being replied to directly, or `nil` when the event is not a
    /// reply.
    public let parentID: String?
    /// The event that opened the thread. Equal to `parentID` for a direct reply
    /// to the opener.
    public let rootID: String?

    public init(parentID: String?, rootID: String?) {
        self.parentID = parentID
        self.rootID = rootID
    }

    /// Whether the event is a reply at all.
    public var isReply: Bool {
        parentID != nil
    }
}
