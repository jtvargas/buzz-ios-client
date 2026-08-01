import Foundation

/// Who may edit or delete one message, decided the way the relay decides it.
///
/// # Why the two are not one flag
///
/// They genuinely differ, and flattening them would either hide a working control or
/// offer one that fails:
///
/// - **Delete** (`kind:9005`) is accepted from the author, from a channel **owner or
///   admin** for anybody's message, or from the owning human of the agent that wrote it
///   (`buzz-relay` `side_effects.rs`, the `9005` arm).
/// - **Edit** (`kind:40003`) is accepted from the author or the agent's owning human —
///   **and not from an admin** (`ingest.rs`, `validate_edit_ownership`).
///
/// So a channel admin may remove somebody's message but may not rewrite it, which is a
/// deliberate rule about what moderation is: taking something down is moderation, putting
/// different words in somebody's mouth is not. The reference mobile client offers a single
/// *author-or-owner* flag for both, which is narrower than the relay on delete; this
/// follows the relay instead, so an admin's real power is reachable.
///
/// # These are affordances, not authorization
///
/// The relay re-decides on every event and its answer is the only one that matters — the
/// same footing ``ChannelLifecyclePermissions`` is on. What this buys is a sheet that does
/// not offer an action the relay will refuse, and does not withhold one it would accept.
///
/// One rule is deliberately **not** mirrored here: the relay re-gates an author on current
/// membership, so somebody removed from a private channel cannot reach back and mutate old
/// messages. A reader looking at a channel in this app is a member of it — the case only
/// arises between the removal landing and the surface noticing — and guessing at it locally
/// could only ever *withhold* a control the relay would have accepted. Left to the relay.
public struct MessageAuthority: Sendable, Hashable {
    /// Whether this identity may publish a `kind:40003` edit of the message.
    public let canEdit: Bool
    /// Whether this identity may publish a `kind:9005` deletion of the message.
    public let canDelete: Bool

    public init(canEdit: Bool, canDelete: Bool) {
        self.canEdit = canEdit
        self.canDelete = canDelete
    }

    /// Neither — what a keyless session, a relay notice, or an unsent row gets.
    public static let none = MessageAuthority(canEdit: false, canDelete: false)

    /// Resolves the two answers from the three facts that decide them.
    ///
    /// Pure, so the rule is testable without a database: the store's job is to fetch
    /// `isAuthor`, `ownsAuthor` and `isChannelAdmin`, and this file's job is to know what
    /// they mean.
    ///
    /// - Parameters:
    ///   - isAuthor: the identity wrote the message.
    ///   - ownsAuthor: the identity is the verified NIP-OA owner of the pubkey that wrote
    ///     it — the case that lets a human manage everything their agents say.
    ///   - isChannelAdmin: the identity is an owner or admin of the channel the message is
    ///     in, whether directly or through an agent it owns.
    public static func resolve(
        isAuthor: Bool,
        ownsAuthor: Bool,
        isChannelAdmin: Bool
    ) -> MessageAuthority {
        let isOwnWords = isAuthor || ownsAuthor
        return MessageAuthority(
            canEdit: isOwnWords,
            canDelete: isOwnWords || isChannelAdmin
        )
    }
}
