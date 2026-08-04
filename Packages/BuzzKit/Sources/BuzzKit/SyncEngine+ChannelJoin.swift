import Foundation
import NostrCore
import os

// MARK: - Errors

/// Why joining a channel failed.
///
/// Two cases rather than three, because the relay decides the whole verdict before it
/// answers: `handle_join_request` runs its membership write, its system message, its
/// discovery re-emit and its 44100 notification to completion, and the private and
/// not-found refusals happen earlier still, in ingest. So an `OK` is never provisional —
/// there is no "accepted, ask again later" for this kind, and nothing here has to model
/// one.
public enum ChannelJoinError: Error, Equatable, Sendable {
    /// The relay refused the join, carrying its classified reason: `restricted:` (the
    /// channel is private and wants an invitation), `invalid:` (no such channel, or an
    /// archived one), or `rate-limited:`. Terminal — resending the same request earns
    /// the same answer.
    case rejected(OKReason)
    /// The join never reached a verdict: no authenticated socket, a drop mid-flight, or
    /// a watchdog timeout. Whether the relay committed it is unknown, and a retry is
    /// safe — see the idempotence note on ``SyncEngine/joinChannel(_:onProgress:)``.
    case publishFailed(RelayConnectionError)
}

// MARK: - Progress

/// How far a join has got, for a UI that holds a joining state rather than navigating
/// into a channel that has no messages in it yet.
///
/// Ordered as it is reported, and reported from the actor — a `@MainActor` observer must
/// hop. ``ready`` fires immediately before the call returns, so a caller that only needs
/// to know when to navigate can ignore this entirely and use the return.
public enum ChannelJoinProgress: Sendable, Equatable {
    /// Signing and sending the kind-9021 request.
    case publishing
    /// Reading the relay-signed roster back, to see this identity on it.
    case confirming
    /// Paging the channel's head window, then fetching its threads' replies.
    case hydrating
    /// Everything above is committed locally. Safe to open the channel.
    case ready
}

// MARK: - Public surface

/// Joining an open channel: one NIP-29 join request, then enough hydration that the
/// channel is worth opening when this returns.
///
/// # Why it hydrates rather than just joining
///
/// A join is otherwise only the *right* to read a channel, and the reading is what the
/// reader asked for. Membership alone leaves the standing subscription to be registered
/// by the next directory pass and the history to be paged by the next `.ready`, so a
/// screen opened straight after a successful join draws an empty channel and fills in
/// some seconds later. Doing that work here — inside the call the UI is already showing
/// a spinner for — spends the same time where it is already accounted for.
///
/// # Why a retry is safe
///
/// The relay short-circuits a join from an identity already on the roster before it
/// writes anything or emits anything (`crates/buzz-relay/src/handlers/side_effects.rs`,
/// `handle_join_request`), so a resend after an ambiguous failure cannot produce a second
/// membership, a duplicate `member_joined` system message, or a second notification. That
/// is the opposite of ``createChannel(name:about:isPrivate:)``, which has no fixed point
/// and must not be blind-retried.
public extension SyncEngine {
    /// Joins an open channel, and returns once it is ready to read.
    ///
    /// - Parameters:
    ///   - channelID: The channel to join. Must be open — the relay refuses a self-join
    ///     to a private channel with `restricted:`, and to an archived one with
    ///     `invalid:`, both as ``ChannelJoinError/rejected(_:)``.
    ///   - onProgress: Called as each phase begins, from the engine's actor. Optional.
    /// - Throws: ``ChannelJoinError``. Only the publish throws: everything after it is
    ///   best-effort, because by then the membership is committed on the relay and the
    ///   worst a failed step costs is history this device fetches on its next pass.
    func joinChannel(
        _ channelID: String,
        onProgress: @Sendable @escaping (ChannelJoinProgress) -> Void = { _ in }
    ) async throws {
        onProgress(.publishing)
        try await publishJoinRequest(channelID)

        onProgress(.confirming)
        await confirmJoinedRoster(channelID)

        onProgress(.hydrating)
        await hydrateJoinedChannel(channelID)

        onProgress(.ready)
        requestDirectoryRefresh()
    }
}

// MARK: - Phases

extension SyncEngine {
    /// Logger for the join. Its own category for the same reason the create has one: the
    /// verdict rides in an `OK` message and is never an event, so nothing else records it.
    static let channelJoinLog = Logger(subsystem: "BuzzKit", category: "SyncEngine.channelJoin")

    /// Signs and publishes the kind-9021 request, and maps the relay's answer.
    ///
    /// The `h` tag is the entire payload — the relay reads the channel from it and the
    /// joiner from the signature, and there is nothing else it will accept from a
    /// self-join. Stamped from the engine's injected clock, which the ingest gate requires
    /// to sit within ±15 minutes of the relay's own time.
    ///
    /// A `duplicate:` is classified as success by ``NostrCore/RelayConnection`` and never
    /// reaches here as a rejection, which is the correct reading: it means the relay
    /// already holds this exact request.
    private func publishJoinRequest(_ channelID: String) async throws {
        let event = try await signer.sign(
            kind: .groupJoinRequest,
            content: "",
            tags: [["h", channelID]],
            createdAt: now()
        )
        do {
            let message = try await connection.publishAwaitingResponse(event)
            Self.channelJoinLog.notice(
                """
                Joined channel \(channelID, privacy: .public) \
                (relay said: \(message, privacy: .public))
                """
            )
        } catch RelayConnectionError.publishRejected(let reason) {
            Self.channelJoinLog.error(
                "Join of \(channelID, privacy: .public) refused: \(String(describing: reason), privacy: .public)"
            )
            throw ChannelJoinError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw ChannelJoinError.publishFailed(error)
        }
    }

    /// Reads the channel's relay-signed state back and ingests it, so `channel_member`
    /// names this identity before anything downstream reads membership.
    ///
    /// # Why a read-back rather than waiting for the notification
    ///
    /// The relay does emit a kind-44100 to the joiner, but it emits it *after* the
    /// membership write and best-effort — a warning on failure, not a retry — and it
    /// arrives on the live fan-out whose delivery this device does not control. Waiting on
    /// it would make a join's completion depend on the least reliable of the three things
    /// the relay does. The `#d`-scoped read-back asks for the roster directly, and asks
    /// only once: every side effect is awaited before the `OK` is sent, so by the time the
    /// publish above returned, the roster the relay would serve already names us.
    ///
    /// The `channel_access` row is written here rather than left to the directory pass so
    /// the channel is visible to the sidebar immediately, the same adoption
    /// ``adoptOpenedChannel(_:)`` performs for a created channel or an opened DM.
    ///
    /// Best-effort throughout. A failed read-back costs this channel its name and roster
    /// until the directory refresh at the end of the join, not the join.
    private func confirmJoinedRoster(_ channelID: String) async {
        let events = (try? await subscriptions.query(Self.channelStateFilters(channelID))) ?? []
        _ = try? await store.ingest(batch: events, phase: .backfill)
        if let identity = selfPubkeyHex {
            try? await store.markChannelAccess(identity: identity, channel: channelID, state: .active)
        }
    }

    /// Registers the standing subscription, closes the offline gap, then fetches replies.
    ///
    /// The order is load-bearing and not merely tidy. `threadPrefetchCandidates` joins the
    /// thread summaries against the roots this device holds (``ThreadPrefetch``), so a
    /// reply prefetch issued before the head window has committed has no candidates to
    /// find and silently does nothing. The window comes first, and is awaited.
    ///
    /// Awaited rather than detached, unlike the head reconcile
    /// ``setActiveChannel(_:)`` kicks: this is a caller that asked to *join*, and the
    /// whole point of the call is that the channel is worth opening when it returns.
    private func hydrateJoinedChannel(_ channelID: String) async {
        _ = try? await subscribeChannelContent(channelID)
        await reconcile(channelID, generation: readyGeneration)
        await prefetchThreads(in: channelID)
    }
}
