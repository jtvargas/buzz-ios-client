import Foundation
import NostrCore

/// Reminders on the engine: setting one, revising it, and adopting the ones this
/// identity's other devices publish.
///
/// The engine is the only layer that may touch them, for the same reason it owns read
/// state and channel mutes: the payload is NIP-44 encrypted to self, so both writing one
/// and reading one go through the signer's to-self crypto. The store keeps only decrypted
/// rows.
///
/// Every mutation writes the local row *first* and publishes after. A reminder is a
/// promise the app made to a reader; it has to survive a dead relay, and the Later screen
/// has to answer the tap that made it.
public extension SyncEngine {
    /// Sets a new reminder on a message. Returns the `d` tag, which is the reminder's
    /// identity from here on — `nil` when there is no identity to sign with.
    @discardableResult
    func setReminder(
        target: ReminderTarget,
        notBefore: Int64,
        note: String? = nil
    ) async -> String? {
        guard selfPubkeyHex != nil else { return nil }
        let dTag = Reminders.randomDTag()
        let content = ReminderContent(target: target, note: note, status: .pending)

        try? await store.applyReminder(
            ReminderRow(
                id: dTag,
                eventID: "",
                createdAt: Int64(now().timeIntervalSince1970),
                notBefore: notBefore,
                status: .pending,
                target: target,
                note: note
            )
        )

        await publishReminder(
            dTag: dTag,
            content: content,
            notBefore: notBefore,
            after: 0
        )
        return dTag
    }

    /// Moves an existing reminder to a new due time, keeping it pending.
    func snoozeReminder(_ row: ReminderRow, notBefore: Int64) async {
        // Back to `pending` unconditionally: snoozing is also how a reminder that already
        // fired gets pushed out again, and one that had been completed would otherwise
        // acquire a due time it is not allowed to have.
        let content = ReminderContent(target: row.target, note: row.note, status: .pending)
        await revise(row, content: content, notBefore: notBefore)
    }

    /// Marks a reminder finished. It leaves the pending list and stops being scheduled.
    func completeReminder(_ row: ReminderRow) async {
        let content = ReminderContent(target: row.target, note: row.note, status: .done)
        await revise(row, content: content, notBefore: nil)
    }

    /// Dismisses a reminder without completing it — the Archived tab.
    func cancelReminder(_ row: ReminderRow) async {
        let content = ReminderContent(target: row.target, note: row.note, status: .cancelled)
        await revise(row, content: content, notBefore: nil)
    }

    /// Decrypts and applies reminders from a freshly-ingested batch: this identity's own
    /// echo, and every reminder its other devices set.
    ///
    /// Unlike ``applyIncomingChannelMutes(_:)`` there is nothing to republish. Each
    /// reminder is its own addressable event, so adopting one never leaves this device
    /// holding a more complete picture than the relay — there is no table to merge.
    func applyIncomingReminders(_ events: [NostrEvent]) async {
        guard let selfPubkeyHex else { return }
        for event in events {
            guard event.kind == .reminder,
                  event.pubkey == selfPubkeyHex,
                  let dTag = event.firstValue(forTag: "d"),
                  let plaintext = try? await signer.decryptToSelf(event.content),
                  let content = ReminderContent.decode(plaintext: plaintext)
            else { continue }

            // Only a pending reminder carries a due time. Reading `not_before` off a
            // finished one would resurrect it in the pending list on the next sync.
            let notBefore = content.status == .pending
                ? event.firstValue(forTag: Reminders.notBeforeTag).flatMap(Reminders.parseNotBefore)
                : nil

            try? await store.applyReminder(
                ReminderRow(
                    id: dTag,
                    eventID: event.id,
                    createdAt: event.createdAt,
                    notBefore: notBefore,
                    status: content.status,
                    target: content.target,
                    note: content.note
                )
            )
        }
    }
}

extension SyncEngine {
    /// Publishes a revision of an existing reminder, and writes the local row first.
    private func revise(_ row: ReminderRow, content: ReminderContent, notBefore: Int64?) async {
        try? await store.applyReminder(
            ReminderRow(
                id: row.id,
                eventID: row.eventID,
                createdAt: Swift.max(Int64(now().timeIntervalSince1970), row.createdAt + 1),
                notBefore: notBefore,
                status: content.status,
                target: content.target,
                note: content.note
            )
        )
        await publishReminder(
            dTag: row.id,
            content: content,
            notBefore: notBefore,
            after: row.createdAt
        )
    }

    /// Encrypts a reminder and queues it as one addressable `kind:30300`.
    ///
    /// A finished reminder swaps `not_before` for `expiration`: it has no due time left,
    /// and the tag is what lets the relay collect it a month or two from now instead of
    /// keeping every reminder anyone ever completed. Desktop writes the same pair.
    private func publishReminder(
        dTag: String,
        content: ReminderContent,
        notBefore: Int64?,
        after previousCreatedAt: Int64
    ) async {
        guard let plaintext = try? content.encodedJSON(),
              let ciphertext = try? await signer.encryptToSelf(plaintext)
        else { return }

        var tags = [["d", dTag]]
        if let notBefore {
            tags.append([Reminders.notBeforeTag, String(notBefore)])
        } else {
            tags.append([Reminders.expirationTag, String(Reminders.jitteredExpiration(from: now()))])
        }

        // Strictly newer than the revision this replaces, so the addressable replace
        // resolves by `created_at` alone at a coordinate two devices share.
        let nowSeconds = Int64(now().timeIntervalSince1970)
        let createdAtSeconds = Swift.max(nowSeconds, previousCreatedAt + 1)

        // Channel-less, like read state and mutes: a reminder is user data the relay fans
        // out globally, and the empty channel id is only the outbox row's denormalized
        // scope. It is deliberately *not* the target's channel — an `h` tag here would
        // scope the reminder to a channel and leak which message it points at.
        guard (try? await store.enqueue(
            kind: .reminder,
            content: ciphertext,
            in: "",
            tags: tags,
            with: signer,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))
        )) != nil else { return }

        await drainOutbox()
    }

    /// The reminder filter: `kind:30300` authored by this identity.
    ///
    /// No tag query. Unlike the two `kind:30078` features, which share a kind and are told
    /// apart by `t`, 30300 is reminders and nothing else — so the kind alone is the whole
    /// of it. `#h`-less like every other filter on the global REQ.
    func remindersFilter(selfPubkeyHex: String) -> Filter {
        Filter(authors: [selfPubkeyHex], kinds: [.reminder], limit: 200)
    }
}
