import Foundation
import NostrCore

/// Cross-device channel mutes on the engine: publishing this identity's decisions
/// through the durable outbox, and adopting the ones its other devices publish.
///
/// The engine is the only layer that may touch them, for the same reason it is the
/// only layer that may touch read state: the blob is NIP-44 encrypted to self, so
/// both writing one and reading one go through the signer's to-self crypto. The
/// store keeps only decrypted rows.
public extension SyncEngine {
    /// Mutes or unmutes `channel` for this identity on every device.
    ///
    /// The local row is written first and the blob published after, so the toggle
    /// answers immediately and offline. Publishing is best-effort — a mute is a
    /// convenience, and the next change republishes the whole table anyway.
    func setChannelMuted(_ channel: String, muted: Bool) async {
        guard !channel.isEmpty else { return }
        let updatedAt = Int64(now().timeIntervalSince1970)
        guard let state = try? await store.setChannelMute(channel, muted: muted, updatedAt: updatedAt) else { return }
        await publishChannelMutes(state)
    }

    /// Decrypts and merges `channel-mutes` blobs from a freshly-ingested batch — this
    /// identity's own echo and every other device's blob for it.
    ///
    /// A merge that actually changed something is republished, because the blob this
    /// device holds is now newer than anything on the relay: the other device wrote
    /// what it knew, and this one knows more. The republish is gated on a real change
    /// precisely so two devices cannot answer each other for ever.
    func applyIncomingChannelMutes(_ events: [NostrEvent]) async {
        guard let selfPubkeyHex else { return }
        var changed = false
        for event in events {
            guard event.kind == .readState,
                  event.pubkey == selfPubkeyHex,
                  ChannelMutes.hasValidTags(event),
                  let plaintext = try? await signer.decryptToSelf(event.content),
                  let blob = ChannelMuteBlob.decode(plaintext: plaintext)
            else { continue }
            let didChange = (try? await store.applyChannelMutes(
                blob.channels,
                sourceCreatedAt: event.createdAt,
                sourceEventID: event.id
            )) ?? false
            changed = changed || didChange
        }
        guard changed, let state = try? await store.channelMuteState() else { return }
        await publishChannelMutes(state)
    }
}

extension SyncEngine {
    /// Encrypts the whole mute table and queues it as the one `channel-mutes`
    /// addressable event for this identity.
    ///
    /// The whole table every time, not a delta: the event is replaceable, so a blob
    /// carrying only the channel that just changed would *erase* every other decision
    /// for any device that read it.
    private func publishChannelMutes(_ state: BuzzEventStore.ChannelMuteState) async {
        let blob = ChannelMuteBlob(channels: state.entries)
        guard let plaintext = try? blob.encodedJSON(),
              let ciphertext = try? await signer.encryptToSelf(plaintext)
        else { return }

        // Strictly newer than the last blob seen at this coordinate, so the addressable
        // replace resolves by `created_at` alone. Two devices share this coordinate, so
        // a tie is not a theoretical concern the way it is for a per-device slot.
        let nowSeconds = Int64(now().timeIntervalSince1970)
        let createdAtSeconds = Swift.max(nowSeconds, state.sourceCreatedAt + 1)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))

        // Channel-less: no `h` tag, the same invariant that keeps read state on the
        // global REQ. The empty channel id is only the outbox row's denormalized scope,
        // which the message unions ignore because they filter to kind 9.
        guard let entry = try? await store.enqueue(
            kind: .readState,
            content: ciphertext,
            in: "",
            tags: [ChannelMutes.dTag(), ChannelMutes.tTag()],
            with: signer,
            createdAt: createdAt
        ) else { return }

        try? await store.recordPublishedChannelMutes(
            sourceCreatedAt: entry.event.createdAt,
            sourceEventID: entry.event.id
        )
        await drainOutbox()
    }

    /// The channel-mutes filter: `kind:30078` authored by this identity, scoped by
    /// `#t: ["channel-mutes"]`.
    ///
    /// A second filter rather than a widened ``readStateFilter(selfPubkeyHex:)``,
    /// because a NIP-01 filter ANDs its tag queries: one filter asking for both `t`
    /// values would match an event carrying *both*, which is nothing. `#h`-less like
    /// every other filter on the global REQ — mutes are channel-less user state and
    /// the relay fans them out globally.
    func channelMutesFilter(selfPubkeyHex: String) -> Filter {
        Filter(
            authors: [selfPubkeyHex],
            kinds: [.readState],
            tagQueries: ["t": [ChannelMutes.tTagValue]]
        )
    }
}
