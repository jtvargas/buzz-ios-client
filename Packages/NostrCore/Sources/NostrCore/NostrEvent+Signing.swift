import Foundation

public extension NostrEvent {
    /// Mints a fully-formed, valid event.
    ///
    /// The NIP-01 canonical id is assembled from the given fields, that id is
    /// signed with `key`, and the event is returned carrying both — so the result
    /// satisfies `isValid` by construction. This is the only path that creates a
    /// signed event; decoding the wire is the only other way an instance comes to
    /// exist. It applies no publish policy of its own (an `EventSigner` is the
    /// place that refuses relay-signed kinds); here it is the raw signing step.
    static func signed(
        kind: EventKind,
        content: String,
        tags: [[String]] = [],
        createdAt: Date = Date(),
        with key: PrivateKey
    ) throws -> NostrEvent {
        let pubkey = key.publicKey.hex
        let createdAtUnix = Int64(createdAt.timeIntervalSince1970)
        let idBytes = computeID(
            pubkey: pubkey,
            createdAt: createdAtUnix,
            kind: kind,
            tags: tags,
            content: content
        )
        let signature = try key.signature(for: idBytes)
        return NostrEvent(
            id: idBytes.hexString,
            pubkey: pubkey,
            createdAt: createdAtUnix,
            kind: kind,
            tags: tags,
            content: content,
            sig: signature.hexString
        )
    }
}
