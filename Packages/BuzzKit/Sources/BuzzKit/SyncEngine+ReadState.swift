import Foundation
import NostrCore

/// NIP-RS cross-device read state on the engine: publishing this device's read
/// frontier through the durable outbox, and adopting the frontiers other devices
/// (or this one, echoed) publish.
///
/// The engine is the only layer that may touch read state, because it is the only
/// one holding the identity: a blob's content is NIP-44 encrypted to self, so both
/// building one (``markRead(channel:upTo:)``) and reading one
/// (``applyIncomingReadState(_:)``) go through the signer's to-self crypto. The store
/// keeps only decrypted rows.
public extension SyncEngine {
    /// Marks `channel` read up to `upTo` — a message `created_at` in unix seconds —
    /// and publishes the updated blob through the durable outbox.
    ///
    /// Grow-only: a no-op when this device's own frontier for the channel already
    /// covers `upTo`, so re-opening a channel with nothing new never republishes an
    /// identical blob. The new blob carries every context this device has marked (read
    /// back from its own slot) with `channel` advanced, so the slot stays a complete,
    /// monotonic record. It is stamped strictly newer than the slot's last blob
    /// (NIP-RS clock skew) so the addressable replace never ties on `created_at`.
    ///
    /// Applied locally the instant it is queued so the badge clears before the relay
    /// round-trip; the relay's echo re-applies the identical `(created_at, id)` with no
    /// effect. Best-effort throughout: read state is a convenience layer, so a signer
    /// or store hiccup drops the mark rather than surfacing an error to the caller.
    func markRead(channel: String, upTo: Int64) async {
        guard let selfPubkeyHex else { return }
        guard let identity = try? await store.readStateIdentity() else { return }

        let slot = try? await store.ownReadStateSlot(author: selfPubkeyHex, slot: identity.slotID)
        var contexts = slot?.contexts ?? [:]
        let current = contexts[channel] ?? 0
        guard upTo > current else { return }
        contexts[channel] = upTo

        let blob = ReadStateBlob(clientID: identity.clientID, contexts: contexts)
        guard let plaintext = try? blob.encodedJSON(),
              let ciphertext = try? await signer.encryptToSelf(plaintext)
        else { return }

        // Strictly newer than this slot's last blob so the replace resolves by
        // `created_at` alone rather than an id tiebreak that a monotonic register
        // cannot rely on (NIP-RS Clock Skew).
        let nowSeconds = Int64(now().timeIntervalSince1970)
        let createdAtSeconds = Swift.max(nowSeconds, (slot?.sourceCreatedAt ?? 0) + 1)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))

        // Channel-less: no `h` tag (the invariant that keeps read state on the global
        // REQ, never a per-channel one). The empty channel id is only the outbox row's
        // denormalized scope, which the message unions ignore because they filter to
        // kind 9 — a queued 30078 never renders as a message.
        guard let entry = try? await store.enqueue(
            kind: .readState,
            content: ciphertext,
            in: "",
            tags: [ReadState.dTag(slotID: identity.slotID), ReadState.tTag()],
            with: signer,
            createdAt: createdAt
        ) else { return }

        try? await store.applyReadState(
            author: selfPubkeyHex,
            slot: identity.slotID,
            contexts: contexts,
            sourceCreatedAt: entry.event.createdAt,
            sourceEventID: entry.event.id
        )

        await drainOutbox()
    }

    /// Decrypts and applies read-state blobs from a freshly-ingested batch — this
    /// device's own echo and every other device's blob for the same identity. Only
    /// events that pass the NIP-RS structural gate, are authored by this identity, and
    /// decrypt to a valid blob are applied; anything else is skipped silently (a peer
    /// on a newer schema, or another user's blob the relay happened to include).
    func applyIncomingReadState(_ events: [NostrEvent]) async {
        guard let selfPubkeyHex else { return }
        for event in events {
            guard event.kind == .readState,
                  event.pubkey == selfPubkeyHex,
                  let slot = ReadState.slotID(from: event),
                  let plaintext = try? await signer.decryptToSelf(event.content),
                  let blob = ReadStateBlob.decode(plaintext: plaintext)
            else { continue }
            try? await store.applyReadState(
                author: event.pubkey,
                slot: slot,
                contexts: blob.contexts,
                sourceCreatedAt: event.createdAt,
                sourceEventID: event.id
            )
        }
    }
}

extension SyncEngine {
    /// The global read-state filter: `kind:30078` authored by this identity, scoped
    /// by `#t: ["read-state"]` so the relay serves only read-state blobs and not every
    /// NIP-78 app-data event the user owns.
    ///
    /// **`#h`-less by design.** Read state is workspace-global at the relay (its ingest
    /// treats `kind:30078` as channel-less user state), so it arrives only on a global
    /// subscription — never a per-channel one, whose `#h` it would never match. This
    /// filter is multiplexed with the equally `#h`-less content and membership filters
    /// in the one global REQ; adding an `#h` filter to that REQ would scope the whole
    /// thing to a channel and starve read state (and presence) of delivery.
    func readStateFilter(selfPubkeyHex: String) -> Filter {
        Filter(
            authors: [selfPubkeyHex],
            kinds: [.readState],
            tagQueries: ["t": [ReadState.tTagValue]]
        )
    }
}
