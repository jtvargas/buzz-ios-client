import NostrCore

/// The ephemeral publish path (S-3): presence and typing sends that bypass the
/// outbox entirely.
///
/// Ephemeral kinds (presence 20001, typing 20002) are meaningless within seconds
/// and are never stored, queued, or retried by the relay
/// (``NostrCore/EventKind/isEphemeral``). Our durable send path — the persisted,
/// retried outbox — is the wrong shape for them: a heartbeat that failed to send
/// must be dropped, not resent minutes later under a stale timestamp. So this path
/// signs and hands the event straight to the connection, best-effort, and swallows
/// every failure. The relay answers an ephemeral EVENT with an `OK` like any other,
/// so the publish resolves normally on accept; a rejection or a disconnect is
/// dropped rather than surfaced.
public extension SyncEngine {
    /// Publishes an ephemeral event on a best-effort, fire-and-forget basis.
    ///
    /// Never persisted, never queued through the outbox, never retried. A non-
    /// ephemeral kind is refused outright — this path is only for presence and
    /// typing, whose failures must never become a user-visible error or a retry.
    /// The connection gates the send on authentication and throws fast when the
    /// socket is not live, so a heartbeat issued while suspended is simply dropped.
    ///
    /// - Parameters:
    ///   - kind: an ephemeral kind (20000–29999); any other kind is a no-op.
    ///   - content: the event content (e.g. `"online"` for presence).
    ///   - tags: the event tags (e.g. `[["h", channel]]` for typing; presence is
    ///     channel-less).
    func publishEphemeral(kind: EventKind, content: String, tags: [[String]] = []) async {
        guard kind.isEphemeral else { return }
        guard let event = try? await signer.sign(kind: kind, content: content, tags: tags) else { return }
        try? await connection.publish(event)
    }
}
