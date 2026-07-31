import BuzzKit
import Foundation
import NostrCore
import Observation

/// Drives ``ThreadView`` for one thread: a one-shot fetch of the thread on open,
/// then a live observation that merges replies and reactions as they arrive, plus
/// the reply / react / retry / delete calls.
///
/// Rows are held ascending (oldest first) — a thread is read forwards — exactly as
/// `store.thread(root:)` returns them. The observation re-reads the whole thread on
/// every relevant commit, so a live reply, a withdrawal, or a `pending → sent`
/// transition updates in place rather than appending a duplicate.
///
/// The thread reads its own rows synchronously on the first `body` pass, for the same
/// reason the channel timeline does — see ``primeIfNeeded()``: the bottom anchor is
/// resolved once, against the first layout, so it must have the real content height by
/// then. It shares the channel's tail freeze and day grouping too — a reply arriving
/// while someone reads a long thread moves their place exactly as a channel message does.
@MainActor
@Observable
final class ThreadModel {
    /// The thread's root (opener) id.
    let root: String
    /// The channel the thread lives in, for the reply's `h` scope and send routing.
    let channel: String

    /// The rows to render: the whole thread, or everything up to the frozen boundary
    /// while the reader is away from the bottom.
    private(set) var rows: [TimelineRow] = []
    /// ``rows`` with day separators interleaved, computed once per rows change. The
    /// separator above the thread's own opener is suppressed — see ``items(for:root:)``.
    private(set) var items: [ConversationItem] = []
    /// Bumped whenever the rendered content changes: the item set, or anything drawn
    /// inside a row that can change its height. ``ConversationScaffold`` restores the
    /// reader's place across the settling that follows one of these, and across nothing
    /// else — a `LazyVStack` re-measures unchanged content whenever the container moves,
    /// so its reported height cannot stand in for this (see ``ConversationReaderPlace``).
    private(set) var contentRevision = 0

    /// Surviving reaction groups per row, re-read on the same observation as `rows`.
    private(set) var reactionGroups: [String: [ReactionGroup]] = [:]
    /// The users each row mentions, keyed by message id, re-read on the same
    /// observation as `rows` so `@`-tokens resolve from each message's own `p` tags.
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    private(set) var hasLoaded = false

    /// The reply composer's text and mention tokens — see `ThreadModel+Drafts.swift`.
    var mentionDraft = MentionDraft() { didSet { recordDraft(replacing: oldValue) } }
    /// Where that draft is kept between visits. `nil` in tests, which then keep nothing.
    let drafts: ComposerDrafts?
    let mentionAutocomplete: MentionAutocompleteModel
    /// The pictures the reply composer is carrying, uploaded as they are picked and
    /// cleared by the reply that names them. This thread's own — the channel behind
    /// it keeps a separate list.
    let attachments: ComposerAttachmentsModel
    /// Set when a reply is refused before it leaves the device (over the 64 KiB
    /// ceiling); the view shows it and the draft text is preserved.
    var sendError: String?

    // MARK: - Scroll position

    /// Whether the newest reply is in view. Written by ``ConversationScaffold`` from
    /// scroll geometry; leaving the bottom freezes the rendered tail so an arriving
    /// reply cannot move the reader's place, and returning releases it.
    var isAtBottom = true {
        didSet {
            guard isAtBottom != oldValue else { return }
            // `rows` is the whole thread here: leaving the bottom means the tail was
            // released, so the rendered set and the loaded set are the same list, and it
            // carries the boundary second's own membership.
            if isAtBottom { tail.release() } else { tail.freeze(at: rows.last, among: rows) }
            rebuild()
        }
    }

    /// What the affordances above the reply composer show: how many replies the freeze
    /// is holding back, which one to land on, and whether the newest reply is far enough
    /// below to offer a way back. The channel timeline's own, so a thread cannot grow a
    /// second set of rules — see ``ConversationJumpState``.
    let jump = ConversationJumpState()

    /// Bumped to ask the scaffold to scroll. Settable across the module rather than
    /// `private(set)` for the reason ``ChannelTimelineModel/jumpToken`` is — the jumps
    /// that bump it are in `ThreadModel+Jump.swift`.
    var jumpToken = 0
    /// Where the next bump of ``jumpToken`` lands.
    var jumpTarget: ConversationJumpTarget = .bottom

    private let store: BuzzEventStore
    /// Internal rather than `private` because the send that uses it lives beside this
    /// file, in `ThreadModel+Sending.swift` — Swift's `private` is file-scoped. Same
    /// reason ``ChannelTimelineModel/sender`` is internal. Immutable, so widening it
    /// exposes no mutation.
    let sender: any MessageSending
    private let opener: any ThreadOpening
    /// Where own typing goes. Internal for the same reason the channel timeline's is:
    /// the publish itself lives in `ThreadModel+Typing.swift`.
    let typing: any EphemeralPublishing
    /// The minimum gap between own-typing publishes. The channel's number — a peer's
    /// indicator lapses after 8 s, so anything under that keeps it alive without
    /// publishing on every keystroke.
    let typingThrottle: Duration
    /// The monotonic clock the throttle measures against, injected so a test drives it.
    let clock: @Sendable () -> ContinuousClock.Instant
    /// When own typing was last published. Not observable: nothing renders it.
    @ObservationIgnored var lastTypingPublish: ContinuousClock.Instant?
    /// The local identity's hex pubkey, for own-reaction highlighting and delete.
    let selfPubkey: String?

    /// Every row the thread holds, ascending, whether or not it is being rendered.
    private var loaded: [TimelineRow] = []
    /// The boundary behind which arrivals are held while the reader reads. Internal
    /// for the same reason the jump properties above are: `ThreadModel+Jump.swift`
    /// releases it.
    var tail = TimelineTail()

    /// Whether ``primeIfNeeded()`` has already read the thread. Not observable: nothing
    /// reads it, and it is written from inside a `body`.
    @ObservationIgnored private var hasPrimed = false

    init(
        root: String,
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        opener: any ThreadOpening,
        typing: any EphemeralPublishing = NoopEphemeralPublisher(),
        drafts: ComposerDrafts? = nil,
        uploader: (any MediaUploading)? = nil,
        selfPubkey: String?,
        typingThrottle: Duration = .seconds(3),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.root = root
        self.channel = channel
        self.store = store
        self.sender = sender
        self.opener = opener
        self.typing = typing
        self.drafts = drafts
        self.typingThrottle = typingThrottle
        self.clock = clock
        self.selfPubkey = selfPubkey
        attachments = ComposerAttachmentsModel(uploader: uploader)
        mentionAutocomplete = MentionAutocompleteModel(
            channel: channel,
            store: store,
            selfPubkey: selfPubkey
        )
    }

    /// Reads the thread and its per-row reactions and mentions synchronously — once, so
    /// the scroll view's initial bottom anchor resolves against real content. Whatever
    /// the store already holds; the relay fetch and the observation both still run and
    /// merge on top.
    ///
    /// Called from the top of ``ThreadView``'s `body`, not from `init`, for the reason
    /// ``ChannelTimelineModel/primeIfNeeded()`` records: `State(initialValue:)` evaluates
    /// its argument on every re-initialisation of the view struct, so a pushed thread was
    /// constructing a throwaway model — and running three blocking store reads on the
    /// main actor — on every database commit. `body` still runs before layout, so the
    /// pre-layout content guarantee is unchanged.
    func primeIfNeeded() {
        guard !hasPrimed else { return }
        hasPrimed = true
        restoreDraft()
        let ids = apply(fetchThread())
        applyReactions(fetchReactions(for: ids))
        applyMentions(fetchMentions(for: ids))
    }

    // MARK: - Open + observe

    /// Renders the thread from the local store immediately, pulling the thread from
    /// the relay in parallel, then consumes the observation until cancelled. Attach
    /// with SwiftUI's `.task`.
    ///
    /// Observation and the one-shot fetch run concurrently — the fetch never gates
    /// the first render. Gating it did: the thread laid out empty and only filled after
    /// a relay round-trip, so the scaffold's bottom anchor resolved against empty
    /// content and left a gap under the newest message. `init` now reads the store
    /// before any of this, so even the observation's first emission is not the thread's
    /// first content; the fetch's replies merge in live as they land.
    ///
    /// The one-shot fetch still pulls replies that live fan-out may not have
    /// delivered; the observation re-reads on the commit that ingest raises, so no
    /// reply is missed between the fetch and the subscription.
    func run() async {
        async let opened: Void = openOnce()
        await observe()
        _ = await opened
    }

    /// The one-shot thread fetch, run concurrently with the observation so it never
    /// delays the first render. A failure is dropped: the live observation still
    /// carries whatever the store already holds and whatever fan-out later delivers.
    private func openOnce() async {
        _ = try? await opener.openThread(root: root)
    }

    private nonisolated func observe() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let thread = fetchThread()
                let ids = await apply(thread)
                let groups = fetchReactions(for: ids)
                await applyReactions(groups)
                let mentions = fetchMentions(for: ids)
                await applyMentions(mentions)
            }
        } catch {
            // Ends on cancellation or teardown; last snapshot stays on screen.
        }
    }

    /// Reads the whole thread off the main actor. `store` and `root` are immutable,
    /// so this is safe from the `nonisolated` observation loop.
    private nonisolated func fetchThread() -> [TimelineRow] {
        (try? store.thread(root: root)) ?? []
    }

    @discardableResult
    private func apply(_ thread: [TimelineRow]) -> [String] {
        loaded = thread
        rebuild()
        // Guarded like the rest — see ``ChannelTimelineModel/mergeHead(_:)``.
        if !hasLoaded { hasLoaded = true }
        return thread.map(\.id)
    }

    /// Re-derives the rendered rows and their grouped items from the loaded thread.
    /// Internal for the reason the jump state is: `ThreadModel+Jump.swift` re-derives
    /// after releasing the tail.
    func rebuild() {
        // A thread opened before its own opener had landed had no row to freeze at, so a
        // reader who left the bottom of it armed nothing — and `isAtBottom` has no
        // `false → false` transition to recover on. The first content to appear while they
        // are still away becomes the boundary: it renders, and later replies are held.
        if !isAtBottom, !tail.isFrozen, let newest = loaded.last {
            tail.freeze(at: newest, among: loaded)
        }

        let split = tail.split(loaded)
        // Equal values are not written back, for the reason
        // ``ChannelTimelineModel/rebuild()`` records: an arrival held behind the freeze
        // must move the pill's count and nothing else.
        if rows != split.rendered { rows = split.rendered }
        let grouped = Self.items(for: split.rendered, root: root)
        if items != grouped {
            items = grouped
            contentRevision += 1
        }
        jump.hold(count: split.held.count, firstID: split.held.first?.id)
    }

    /// The thread's rendered items, with the separator above its own opener removed.
    ///
    /// A thread starts at its opener — the reader arrived by tapping it — so a `Today`
    /// hairline above the very first row labels a boundary that is not there. Only the
    /// leading separator is dropped, and only when the opener really is the first row:
    /// a reply that somehow predates its root (relay clock skew) leaves a genuine day
    /// boundary in place.
    static func items(for rows: [TimelineRow], root: String) -> [ConversationItem] {
        let grouped = ConversationGrouping.items(for: rows)
        guard case .day? = grouped.first,
              grouped.dropFirst().first?.message?.id == root
        else { return grouped }
        return Array(grouped.dropFirst())
    }

}

// MARK: - Reactions & row actions

extension ThreadModel {
    /// The reaction groups to render under a row, empty when it has none.
    func reactions(for id: String) -> [ReactionGroup] { reactionGroups[id] ?? [] }

    /// Whether a row is the local identity's own send — the gate on delete.
    func isOwn(_ row: TimelineRow) -> Bool {
        guard let selfPubkey else { return false }
        return row.pubkey == selfPubkey
    }

    nonisolated func fetchReactions(for ids: [String]) -> [String: [ReactionGroup]] {
        (try? store.reactions(for: ids, selfPubkey: selfPubkey)) ?? [:]
    }

    func applyReactions(_ groups: [String: [ReactionGroup]]) {
        if reactionGroups != groups {
            reactionGroups = groups
            contentRevision += 1
        }
    }

    /// The users a row mentions, empty when it mentions none — handed to the row's
    /// resolver so `@`-tokens resolve from the message's own data.
    func mentions(for id: String) -> [MentionRef] {
        mentionRefs[id].map { Array($0) } ?? []
    }

    nonisolated func fetchMentions(for ids: [String]) -> [String: MentionRefList] {
        (try? store.mentions(for: ids)) ?? [:]
    }

    func applyMentions(_ mentions: [String: MentionRefList]) {
        if mentionRefs != mentions {
            mentionRefs = mentions
            contentRevision += 1
        }
    }

    /// Sends a reaction on a message in the thread through the durable send path.
    func react(_ emoji: String, on targetID: String) {
        let channel = self.channel
        let sender = self.sender
        Task {
            try? await sender.enqueue(
                kind: .reaction,
                content: emoji,
                in: channel,
                tags: OutboundTags.reaction(target: targetID),
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
        }
    }

    /// Toggles a chip: withdraws the local identity's own reaction when highlighted,
    /// otherwise adds that emoji.
    func toggleReaction(_ group: ReactionGroup, on targetID: String) {
        guard group.reactedBySelf, let reactionID = group.selfReactionID else {
            react(group.emoji, on: targetID)
            return
        }
        let channel = self.channel
        let sender = self.sender
        Task {
            try? await sender.enqueue(
                kind: .deletion,
                content: "",
                in: channel,
                tags: OutboundTags.withdrawal(reactionID: reactionID),
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
        }
    }

    /// Returns a failed reply to the queue and redrains — the "tap to retry" action.
    func retry(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.retry(eventID) }
    }

    /// Drops an own pending or failed reply.
    func delete(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.discard(eventID) }
    }
}

/// The same five the channel's model already had — see the note on
/// ``ChannelTimelineModel``'s conformance. It is what lets one actions sheet serve both
/// surfaces.
extension ThreadModel: MessageActing {}
