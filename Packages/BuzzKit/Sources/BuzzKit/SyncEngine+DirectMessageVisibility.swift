import Foundation
import NostrCore

// MARK: - Public surface

/// Hiding a direct message: the write half of NIP-DV, whose read half is
/// ``ChannelDirectoryClient/fetch(selfPubkey:previouslyActiveChannels:)``.
///
/// # There is no unhide command
///
/// The relay derives hide state from two commands that already exist: kind 41012 sets it,
/// and kind 41010 — the same open-or-create behind ``openDirectMessage(with:)`` — clears
/// it on the existing-DM branch. So the way back from a hidden DM is to open it again,
/// which is why nothing here is paired with an `unhideDirectMessage`.
public extension SyncEngine {
    /// Hides the direct message `channelID` from this identity's own sidebar.
    ///
    /// Presentation, not membership. The relay keeps you an active participant of the DM,
    /// keeps delivering its messages, and keeps accepting what you write; the other
    /// person's view is untouched. Only ``BuzzEventStore/channelList(selfPubkey:)`` stops
    /// listing it, because its access row is now ``ChannelAccessState/hidden``.
    ///
    /// Returns once the relay has accepted the command *and* that access row is written,
    /// so by the time a caller can react the row has already left the sidebar.
    ///
    /// - Throws: ``DirectMessageError/rejected(_:)`` when the relay refused — you are not
    ///   a member, the id does not name a DM, or it is not a channel id at all — and
    ///   ``DirectMessageError/publishFailed(_:)`` when the command never reached a verdict.
    func hideDirectMessage(_ channelID: String) async throws {
        try await publishHideCommand(channelID)

        // The local demotion is what makes the row leave *now* rather than a round trip
        // later: `channel_access` is inside ``DatabaseSignal``'s tracked region, so this
        // commit is itself what re-reads the sidebar.
        if let identity = selfPubkeyHex {
            try? await store.markChannelAccess(
                identity: identity,
                channel: channelID,
                state: .hidden
            )
        }

        // And this is what confirms it against the relay rather than leaving the app
        // holding a local opinion. Safe to fire immediately — see the note on
        // ``publishHideCommand(_:)`` about the snapshot being written before the `OK`.
        requestDirectoryRefresh()
    }
}

// MARK: - The command

extension SyncEngine {
    /// Publishes one kind-41012 command and returns when the relay has accepted it.
    ///
    /// # Why the refresh that follows cannot un-hide what this just hid
    ///
    /// The relay recomputes and publishes the viewer's kind-30622 snapshot as a
    /// post-commit side effect of accepting this command, and — the load-bearing part —
    /// it *awaits* that publication before answering (`handle_dm_hide` step 5, ahead of
    /// its `IngestResult`). So an `OK` in hand means the snapshot naming this DM is
    /// already readable, and the directory pass fired right after it reads the new one
    /// rather than racing the old.
    ///
    /// The one case where it does not: that publication is best-effort, and a failure is
    /// only warned about relay-side. Then the next directory pass finds this DM absent
    /// from the snapshot and promotes it back to `.active`, and the row returns. That is
    /// the honest outcome — the relay does not consider it hidden — and it is why the
    /// local mark above is a head start on the answer rather than a substitute for it.
    private func publishHideCommand(_ channelID: String) async throws {
        let event = try await signHideCommand(channelID)
        do {
            let message = try await connection.publishAwaitingResponse(event)
            Self.directMessageLog.notice(
                """
                DM \(channelID, privacy: .public) hidden \
                (relay said: \(message, privacy: .public))
                """
            )
        } catch RelayConnectionError.publishRejected(let reason) {
            throw DirectMessageError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw DirectMessageError.publishFailed(error)
        }
    }

    /// Signs the hide command: `h` names the DM, the content is empty.
    ///
    /// The nonce is here for the same reason ``signOpenCommand(peerHex:)`` carries one. A
    /// Nostr event id is a hash of the author, timestamp, kind, tags and content and has
    /// no randomness of its own, so two hides of one DM inside a wall-clock second would
    /// be the *same event*, and the relay's id dedupe answers the second with
    /// `duplicate: already processed` having executed nothing. That is not a hypothetical
    /// ordering here: hide → re-open → hide is a sequence a person can perform, and
    /// without a fresh id per attempt the last hide would silently not take.
    ///
    /// Stamped from the engine's injected clock, which the relay's ingest gate requires
    /// to sit within ±15 minutes of its own time.
    private func signHideCommand(_ channelID: String) async throws -> NostrEvent {
        try await signer.sign(
            kind: .directMessageHide,
            content: "",
            tags: [["h", channelID], ["nonce", UUID().uuidString]],
            createdAt: now()
        )
    }
}
