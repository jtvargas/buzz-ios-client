import Foundation
import NostrCore
import os

// MARK: - Result

/// The outcome of an open-or-create: which channel to show, and whether the relay
/// had to make it.
public struct DirectMessageOpen: Sendable, Equatable {
    /// The DM channel's id — the same value every other Buzz surface keys a channel
    /// on (`h` on messages, `d` on the relay-signed group state).
    public let channelID: String
    /// Whether the relay created the channel on this call. `false` means the DM
    /// already existed and the relay merely un-hid it — the "open the existing one"
    /// path, and just as much a success as `true`.
    public let wasCreated: Bool

    public init(channelID: String, wasCreated: Bool) {
        self.channelID = channelID
        self.wasCreated = wasCreated
    }
}

// MARK: - Errors

/// Why opening a direct message failed.
///
/// A closed set rather than a message string, so a UI can tell "that is not a
/// pubkey" (fix the input) from "this deployment refused you" (nothing to retry)
/// from "the relay answered something we cannot read" (a protocol mismatch worth
/// reporting) without matching on prose.
public enum DirectMessageError: Error, Equatable, Sendable {
    /// The peer identifier was not a 32-byte hex pubkey or an `npub1…`. Caught
    /// before the wire; the relay would only answer `invalid:`.
    case invalidPeerPubkey(String)
    /// The relay refused the command, carrying its classified reason. Terminal:
    /// `invalid:` (malformed input, too many peers, stale timestamp), `restricted:`
    /// (the deployment's membership gate), or an `error:` that survived its one
    /// retry. Resending the same command earns the same answer.
    case rejected(OKReason)
    /// Every attempt came back as an already-processed event id, so no attempt ever
    /// carried the payload. Vanishingly unlikely — it needs a fresh UUID per attempt
    /// to collide — and reported rather than retried forever.
    case duplicateEventIDUnresolved(attempts: Int)
    /// The relay accepted the command but its `OK` message was not a decodable
    /// `response:{…}` payload carrying a channel id. Carries the raw message.
    case malformedResponse(String)
    /// The command never reached a verdict: no authenticated socket, a drop
    /// mid-flight, or a watchdog timeout.
    case publishFailed(RelayConnectionError)
}

// MARK: - Public surface

/// Opening a direct message: one relay command that resolves to a channel id,
/// whether or not the DM already existed.
///
/// # One event does open-or-create
///
/// The relay's kind-41010 command is idempotent server-side on a hash of the
/// participant set, so the client must **not** look for an existing DM first. A
/// local search would be a race (two devices could both miss and both create) and a
/// wasted round trip, and it could not see a DM the relay knows about but this
/// device has never synced. Publishing the command unconditionally is the only
/// correct shape: the relay either creates the channel or hands back the one that
/// already exists, and says which it did.
public extension SyncEngine {
    /// Opens the direct message with `peer`, creating it if the relay does not
    /// already have one, and returns its channel id — what a UI navigates to.
    ///
    /// - Parameter peer: The peer's pubkey as lowercase or uppercase 64-hex, or a
    ///   NIP-19 `npub1…`. This identity is *not* included by the caller; the relay
    ///   merges and dedupes it into the participant set.
    /// - Returns: The DM channel's id. By the time this returns, the channel's
    ///   relay-signed state has been read back and ingested and its live
    ///   subscription is open, so the channel exists locally.
    @discardableResult
    func openDirectMessage(with peer: String) async throws -> String {
        try await openOrCreateDirectMessage(with: peer).channelID
    }

    /// Opens the direct message with `peer` as ``openDirectMessage(with:)`` does,
    /// additionally reporting whether this call was the one that created it.
    func openOrCreateDirectMessage(with peer: String) async throws -> DirectMessageOpen {
        let peerHex = try Self.normalizedPubkey(peer)
        let opened = try await runOpenDirectMessageCommand(peerHex: peerHex)
        Self.directMessageLog.notice(
            """
            DM open resolved to channel \(opened.channelID, privacy: .public) \
            (created: \(opened.wasCreated, privacy: .public))
            """
        )
        await adoptOpenedChannel(opened.channelID)
        return opened
    }
}

// MARK: - The command

extension SyncEngine {
    /// The literal prefix the relay puts in front of a command's JSON result inside
    /// the `OK` message. Stripped before decoding.
    static let commandResponsePrefix = "response:"

    /// How many re-signed attempts a same-second event-id collision may earn before
    /// the open is reported as unresolved.
    ///
    /// Three, because the situation the budget exists for is already
    /// self-correcting: each attempt draws a fresh UUID, so a second collision needs
    /// two UUID collisions in a row. The bound is here to make a relay that answers
    /// `duplicate:` for some *other* reason fail fast and visibly instead of spinning
    /// on the wire forever.
    static let maxNonceResigns = 3

    /// Logger for the DM-open command. Its own category so the create-versus-reopen
    /// verdict and any re-sign are observable in a session log — the outcome is
    /// carried in an `OK` message and never as an event, so nothing else records it.
    static let directMessageLog = Logger(subsystem: "BuzzKit", category: "SyncEngine.directMessages")

    /// Publishes the open-or-create command, applying the retry policy, and returns
    /// the relay's parsed answer.
    ///
    /// # The retry policy, and why each arm is shaped the way it is
    ///
    /// - **An already-processed event id** (`duplicate:`) is not a failure of the
    ///   command; it means the relay recognised the *event* and did nothing, so no
    ///   payload came back. Re-sign with a fresh nonce — a new event id — and send
    ///   again, bounded by ``maxNonceResigns``.
    /// - **A relay internal error** is retried exactly **once**. This is not blind
    ///   optimism: that error is what a lost race between two devices creating the
    ///   same DM looks like (one of them hits a unique-index violation, and the relay
    ///   has no retry of its own). The retry therefore finds the row the winner
    ///   committed and takes the existing-DM fast path.
    /// - **Everything else the relay states** — `invalid:`, `restricted:`,
    ///   `rate-limited:`, `auth-required:` — is surfaced untouched. Resending an
    ///   identical command would earn an identical refusal, and an interactive open
    ///   is the wrong place to sit on a backoff schedule: the caller can act on the
    ///   typed reason (fix the input, tell the user the deployment refused, offer to
    ///   try again) far better than this loop can.
    func runOpenDirectMessageCommand(peerHex: String) async throws -> DirectMessageOpen {
        var nonceResigns = 0
        var retriedInternalError = false

        while true {
            let event = try await signOpenCommand(peerHex: peerHex)

            switch try await sendOpenCommand(event) {
            case let .opened(result):
                return result

            case .alreadyProcessedEventID:
                guard nonceResigns < Self.maxNonceResigns else {
                    throw DirectMessageError.duplicateEventIDUnresolved(attempts: nonceResigns + 1)
                }
                nonceResigns += 1
                Self.directMessageLog.notice(
                    "DM open deduped on event id; re-signing with a fresh nonce (resign \(nonceResigns))"
                )

            case let .relayInternalError(reason):
                // The two-device create race: retry once, which takes the fast path.
                guard !retriedInternalError else { throw DirectMessageError.rejected(reason) }
                retriedInternalError = true
                Self.directMessageLog.notice("DM open hit a relay internal error; retrying once")
            }
        }
    }

    /// What one attempt at the command produced: an answer, or one of the two
    /// conditions the caller retries. Anything terminal is thrown, not returned.
    private enum OpenCommandOutcome {
        case opened(DirectMessageOpen)
        case alreadyProcessedEventID
        case relayInternalError(OKReason)
    }

    /// Sends one signed attempt and classifies the relay's verdict.
    private func sendOpenCommand(_ event: NostrEvent) async throws -> OpenCommandOutcome {
        let message: String
        do {
            message = try await connection.publishAwaitingResponse(event)
        } catch RelayConnectionError.publishRejected(let reason) {
            if case .error = reason { return .relayInternalError(reason) }
            throw DirectMessageError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw DirectMessageError.publishFailed(error)
        }

        // The relay reports an id it has already seen either way round — as an
        // accepting `OK` whose message is `duplicate: already processed`, or as an
        // `OK(false)` the connection classifies as success. Both arrive here as a
        // returned message, so one check covers both.
        if case .duplicate = OKReason(message: message) { return .alreadyProcessedEventID }

        return .opened(try Self.parseOpenResponse(message))
    }

    /// Signs one attempt at the open-or-create command.
    ///
    /// # The nonce is load-bearing
    ///
    /// A Nostr event id is `sha256(pubkey, created_at, kind, tags, content)` and
    /// carries no randomness of its own. Two opens of the same DM inside one
    /// wall-clock second would therefore hash to the *same* id, and the relay's
    /// event-id dedupe answers the second with `accepted: true`,
    /// `"duplicate: already processed"` and **no payload** — a caller left with no
    /// channel id even though nothing went wrong. (The reference Flutter client has
    /// exactly this defect and throws.) A fresh UUID per attempt makes every attempt
    /// a distinct event, which is also what lets the retry arms above re-send at all:
    /// ``RelayConnection`` refuses a second in-flight publish of one event id.
    ///
    /// Two things are deliberately *not* in the tags. No `d` tag: on a command kind
    /// it would activate NIP-33 replace semantics and the relay would answer
    /// `Duplicate` with no payload. No `p` tag for this identity: the relay merges
    /// and dedupes the authenticated author into the participant set, so tagging self
    /// would only spend one of the eight allowed slots.
    ///
    /// Stamped from the engine's injected clock, which the relay's ingest gate
    /// requires to sit within ±15 minutes of its own time.
    private func signOpenCommand(peerHex: String) async throws -> NostrEvent {
        try await signer.sign(
            kind: .directMessageOpen,
            content: "",
            tags: [["p", peerHex], ["nonce", UUID().uuidString]],
            createdAt: now()
        )
    }
}

// MARK: - Pure helpers

extension SyncEngine {
    /// The lowercase 64-hex form of a peer identifier.
    ///
    /// Accepts the hex a directory hands out in either case and with surrounding
    /// whitespace, and a NIP-19 `npub1…` — a UI that lets someone paste an identifier
    /// will see both. Anything else is refused before the wire: the relay answers a
    /// malformed key with `invalid:`, and a round trip is a poor way to learn a string
    /// was never a pubkey.
    static func normalizedPubkey(_ raw: String) throws -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("npub1"), let key = try? PublicKey(npub: lowered) {
            return key.hex
        }
        guard let bytes = Hex.decode(lowered), bytes.count == 32 else {
            throw DirectMessageError.invalidPeerPubkey(raw)
        }
        return lowered
    }

    /// Decodes the relay's command answer: the literal `response:` prefix followed by
    /// JSON.
    ///
    /// `created: false` is a **success**, not a failure — it is precisely the "the DM
    /// already existed" outcome, and the caller navigates to the same channel either
    /// way. `created` is therefore decoded tolerantly, absent meaning "not created":
    /// the channel id is the only field a caller cannot proceed without, and the
    /// read-back that follows runs whatever the flag says.
    static func parseOpenResponse(_ message: String) throws -> DirectMessageOpen {
        guard message.hasPrefix(commandResponsePrefix) else {
            throw DirectMessageError.malformedResponse(message)
        }
        let json = Data(message.dropFirst(commandResponsePrefix.count).utf8)
        guard let payload = try? JSONDecoder().decode(OpenResponsePayload.self, from: json),
              !payload.channelID.isEmpty
        else {
            throw DirectMessageError.malformedResponse(message)
        }
        return DirectMessageOpen(channelID: payload.channelID, wasCreated: payload.created ?? false)
    }
}

/// The open-or-create command's JSON answer, in its wire spelling.
private struct OpenResponsePayload: Decodable {
    let channelID: String
    let created: Bool?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case created
    }
}

// MARK: - Read-back

extension SyncEngine {
    /// The historical read-back filters for one channel's relay-signed state: the
    /// metadata (39000) and the member roster (39002), each `#d`-scoped to the channel
    /// and limited to the single newest addressable replacement. Admins (39001) are
    /// deliberately absent — nothing in the projector reads them.
    ///
    /// `#h`-less, like every other group-state fetch (``discoveryFilter``,
    /// ``rediscoverAndReconcile(_:generation:)``): these are addressable events keyed
    /// by `d`, not channel-scoped traffic keyed by `h`.
    static func channelStateFilters(_ channel: String) -> [Filter] {
        [
            Filter(kinds: [.groupMetadata], limit: 1, tagQueries: ["d": [channel]]),
            Filter(kinds: [.groupMembers], limit: 1, tagQueries: ["d": [channel]]),
        ]
    }

    /// Makes a freshly-opened channel real locally: read its relay-signed state back,
    /// ingest it, open its live subscription, and schedule its head reconcile.
    ///
    /// # Why the read-back must be explicit
    ///
    /// A successful *create* does make the relay publish kind 39000/39002 for the new
    /// channel — but post-commit, best-effort, and stored **channel-scoped**, so they
    /// never reach the engine's `#h`-less global REQ (which does not even carry these
    /// kinds; see ``contentFilter()``). A successful *re-open* republishes neither. Of
    /// the paths that would eventually deliver them, the one-shot discovery query runs
    /// only on the next `.ready` — a reconnect away — and the per-participant kind-44100
    /// notification that *does* arrive live fires only on a create and is itself
    /// best-effort. An interactive open must not depend on any of that, so this issues
    /// the `#d`-scoped historical REQ itself and ingests the answer through the store's
    /// one verification choke point.
    ///
    /// Both filters ride a single REQ: NIP-01 ORs the filters in one subscription, so
    /// this is two filter shapes and one round trip rather than two.
    ///
    /// Then the standing per-channel content subscription — the only live path for
    /// channel traffic — is opened before returning, because it is a cheap REQ and a
    /// DM the user is about to look at should already be receiving messages. The head
    /// reconcile is scheduled and *not* awaited: paging history over HTTP must not hold
    /// up a caller that only needs somewhere to navigate to. It doubles as a second
    /// chance at the group state, since the relay publishes it best-effort after the
    /// commit and may not have written it when the ack arrived.
    ///
    /// Best-effort throughout: the channel id is already known and returned, so a
    /// failed read-back costs the channel's title and roster until the next discovery
    /// pass, not the open itself.
    func adoptOpenedChannel(_ channel: String) async {
        let events = (try? await subscriptions.query(Self.channelStateFilters(channel))) ?? []
        _ = try? await store.ingest(batch: events, phase: .backfill)
        _ = try? await subscribeChannelContent(channel)
        scheduleChannelReconcile(channel)
    }
}
