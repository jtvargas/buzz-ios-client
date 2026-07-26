import BuzzKit
import Foundation
import GRDB
import NostrCore
import Observation

/// Drives ``ChannelTimelineView`` for one channel: a live head observation, keyset
/// pagination of older history, and the send / retry calls.
///
/// Rows are held ascending (oldest first) so the view can anchor to the bottom and
/// render newest-last. The live observation re-reads the newest page on every
/// relevant commit; older pages are loaded on demand and merged by id, so an edit,
/// a deletion, or a `pending → sent` transition updates the *same* row in place
/// rather than appearing twice.
@MainActor
@Observable
final class ChannelTimelineModel {
    let channel: String

    /// The loaded messages, ascending by `(createdAt, id)` — the total order the
    /// keyset query pages on, so "newest" means the same thing here and in the DB.
    private(set) var rows: [TimelineRow] = []
    /// Surviving reaction groups for each loaded row, keyed by message id. Re-read
    /// on the same observation as the rows, so a react, a withdrawal, or a peer's
    /// reaction updates the chips live without a second pipeline.
    private(set) var reactionGroups: [String: [ReactionGroup]] = [:]
    /// The users each loaded row mentions, keyed by message id, resolved from each
    /// message's own `p` tags. Re-read on the same observation as the rows, so a
    /// mentioned user's profile landing updates the rendered name live (WS-1 #9).
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    private(set) var hasLoaded = false
    /// Whether an older page may still exist before the oldest loaded row.
    private(set) var hasMoreOlder = true
    private(set) var isLoadingOlder = false

    /// The composer's wire text plus identity-bearing selected mention tokens.
    var mentionDraft = MentionDraft()
    var draft: String {
        get { mentionDraft.text }
        set { mentionDraft = MentionDraft(text: newValue) }
    }
    let mentionAutocomplete: MentionAutocompleteModel
    /// Set when a send is refused before it leaves the device (over the 64 KiB
    /// ceiling); the view shows it and the draft text is preserved.
    var sendError: String?

    /// The `before` cursor most recently handed to `store.timeline(before:)`. A
    /// test seam: it is exactly the keyset position paged from, proving pagination
    /// never falls back to offset paging (spec §Step 1 tests).
    private(set) var lastOlderCursor: TimelineCursor?

    private let store: BuzzEventStore
    private let sender: any MessageSending
    private let typing: any EphemeralPublishing
    /// Marks the channel read as messages come into view (mark-on-view). `nil` in
    /// tests that do not exercise read state.
    private let readStateMarking: (any ReadStateMarking)?
    private let pageSize: Int
    /// The local identity's hex pubkey, for own-reaction highlighting and the
    /// delete affordance on own pending/failed rows. `nil` degrades to no highlight
    /// and no delete, the same keyless fallback presence uses.
    let selfPubkey: String?

    /// The minimum gap between own-typing publishes while the composer has active
    /// input. Short enough that a peer's 8 s indicator never lapses mid-typing, long
    /// enough not to spam the relay on every keystroke.
    private let typingThrottle: Duration
    /// The monotonic clock the throttle measures against, injected so a test drives
    /// the throttle window without real time.
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// When own typing was last published, for the throttle.
    private var lastTypingPublish: ContinuousClock.Instant?

    /// Loaded rows keyed by id, so a re-read of the head merges into — rather than
    /// duplicates — rows an older page already holds.
    private var loaded: [String: TimelineRow] = [:]
    /// The oldest loaded row's cursor, the basis of the next older page.
    private var earliest: TimelineCursor?

    /// The newest message `created_at` this view has already marked read, so a scroll
    /// back through older history (which never changes the newest row) re-marks
    /// nothing and only a genuinely newer arrival advances the frontier.
    private var lastMarkedReadAt: Int64 = 0

    init(
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        typing: any EphemeralPublishing = NoopEphemeralPublisher(),
        readStateMarking: (any ReadStateMarking)? = nil,
        selfPubkey: String? = nil,
        pageSize: Int = 50,
        typingThrottle: Duration = .seconds(3),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.channel = channel
        self.store = store
        self.sender = sender
        self.typing = typing
        self.readStateMarking = readStateMarking
        self.selfPubkey = selfPubkey
        self.pageSize = pageSize
        self.typingThrottle = typingThrottle
        self.clock = clock
        mentionAutocomplete = MentionAutocompleteModel(
            channel: channel,
            store: store,
            selfPubkey: selfPubkey
        )
    }

    // MARK: - Live observation

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`.
    nonisolated func run() async {
        // Typing is delivered by the engine's standing per-channel content subscription
        // now, whose lifecycle discovery and membership own — the view no longer opens
        // or closes it. This loop is purely the read side: observe, merge, mark read.
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let head = fetch(before: nil)
                let ids = await mergeHead(head)
                // Viewing the channel marks it read up to the newest message — on open
                // (the first snapshot) and on each newer arrival while it is on screen.
                await markReadIfNeeded()
                // Same signal, same reader, off the main actor: re-read reactions and
                // mentions for every loaded row so chips and @-tokens track the
                // timeline exactly.
                let groups = fetchReactions(for: ids)
                await applyReactions(groups)
                let mentions = fetchMentions(for: ids)
                await applyMentions(mentions)
            }
        } catch {
            // Ends on cancellation or teardown; last snapshot stays on screen.
        }
    }

    /// Marks the channel read up to the newest loaded message, once per advance —
    /// mark-on-view. Fires the moment the channel opens (the first head snapshot) and
    /// again whenever a newer message arrives while the view is up; a scroll back
    /// through older history leaves the newest row unchanged, so it re-marks nothing
    /// and never spams the outbox. Fire-and-forget so the observation loop never blocks
    /// on the publish, and grow-only on the engine side so a redundant call is a no-op.
    private func markReadIfNeeded() {
        guard let readStateMarking,
              let newest = rows.last?.createdAt,
              newest > lastMarkedReadAt
        else { return }
        lastMarkedReadAt = newest
        let channel = self.channel
        Task { await readStateMarking.markRead(channel: channel, upTo: newest) }
    }

    /// Reads one page off the main actor. `channel`, `store`, and `pageSize` are
    /// immutable, so this is safe to call from the `nonisolated` observation loop.
    private nonisolated func fetch(before cursor: TimelineCursor?) -> [TimelineRow] {
        (try? store.timeline(channel: channel, before: cursor, limit: pageSize)) ?? []
    }

    /// Merges the newest page into the loaded set and returns every loaded row id,
    /// so the caller can re-read reactions for exactly what is on screen.
    @discardableResult
    private func mergeHead(_ head: [TimelineRow]) -> [String] {
        let firstSnapshot = !hasLoaded
        for row in head { loaded[row.id] = row }
        rebuild()
        hasLoaded = true
        // The head is the newest page; a full page means older history may exist.
        // Decided only on the first snapshot — later head re-reads are new messages
        // at the top, which never re-open the tail.
        if firstSnapshot {
            hasMoreOlder = head.count >= pageSize
        }
        return Array(loaded.keys)
    }

    // MARK: - Pagination

    /// Loads the page immediately older than the oldest loaded row, via the
    /// `(createdAt, id)` keyset cursor — never an offset. Idempotent while a load
    /// is in flight and once history is exhausted.
    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, let cursor = earliest else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        lastOlderCursor = cursor
        let older = fetch(before: cursor)
        for row in older { loaded[row.id] = row }
        rebuild()
        if older.count < pageSize { hasMoreOlder = false }
        // Bring in the older rows' reactions and mentions immediately rather than
        // waiting on the next commit signal, so a scroll back never shows chip-less
        // or unresolved history.
        let ids = Array(loaded.keys)
        applyReactions(fetchReactions(for: ids))
        applyMentions(fetchMentions(for: ids))
    }

    private func rebuild() {
        rows = loaded.values.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
        }
        earliest = rows.first.map(TimelineCursor.init(row:))
    }

    // MARK: - Send / retry

    /// Sends the composer draft. Optimistic and fire-and-forget: the draft is
    /// cleared and the pending row appears through the observation the moment the
    /// outbox row commits, long before the relay's OK. An over-ceiling message
    /// throws before it is queued — the text is restored and surfaced.
    func send() {
        let document = mentionDraft
        let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        mentionDraft = MentionDraft()
        sendError = nil

        let channel = self.channel
        let sender = self.sender
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        Task { [weak self] in
            do {
                try await sender.enqueue(
                    kind: .channelMessage,
                    content: text,
                    in: channel,
                    tags: OutboundTags.message(
                        channel: channel,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
            } catch let error as OutboxError {
                self?.restore(document: document, error: error)
            } catch {
                // A transient send failure leaves the row queued in the outbox for
                // the next drain; nothing to surface and nothing to restore.
            }
        }
    }

    /// Returns a failed send to the queue and redrains — the "tap to retry" action.
    func retry(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.retry(eventID) }
    }

    // MARK: - Typing

    /// Publishes an own typing indicator for this channel as the composer changes,
    /// throttled to at most one publish per ``typingThrottle`` window. Empty input
    /// never publishes — clearing the field is not typing.
    ///
    /// Fire-and-forget: typing is ephemeral (S-3), so a failure is dropped. The
    /// indicator carries the `["h", channel]` tag the relay requires for a channel-
    /// scoped ephemeral (S-5); a non-member's typing would be rejected without it.
    func handleTyping(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let instant = clock()
        if let last = lastTypingPublish, instant - last < typingThrottle { return }
        lastTypingPublish = instant

        let channel = self.channel
        let typing = self.typing
        Task { await typing.publishEphemeral(kind: .typing, content: "", tags: [["h", channel]]) }
    }

    private func restore(document: MentionDraft, error: OutboxError) {
        // Preserve whatever the user has since typed, only restoring if untouched.
        if mentionDraft.text.isEmpty { mentionDraft = document }
        sendError = Self.describe(error)
    }

    private static func describe(_ error: OutboxError) -> String {
        switch error {
        case let .contentTooLarge(bytes, limit):
            "Message is too large (\(bytes) bytes; limit \(limit))."
        case .invalidEvent, .notQueued, .encodingFailed:
            "Couldn't send that message."
        }
    }
}

// MARK: - Reactions & row actions

extension ChannelTimelineModel {
    /// The reaction groups to render under a row, empty when it has none.
    func reactions(for id: String) -> [ReactionGroup] { reactionGroups[id] ?? [] }

    /// Whether a row is the local identity's own send — the gate on the delete
    /// affordance for a pending or failed row.
    func isOwn(_ row: TimelineRow) -> Bool {
        guard let selfPubkey else { return false }
        return row.pubkey == selfPubkey
    }

    /// Reads reactions for `ids` off the main actor. `store` and `selfPubkey` are
    /// immutable, so this is safe to call from the `nonisolated` observation loop.
    nonisolated func fetchReactions(for ids: [String]) -> [String: [ReactionGroup]] {
        (try? store.reactions(for: ids, selfPubkey: selfPubkey)) ?? [:]
    }

    func applyReactions(_ groups: [String: [ReactionGroup]]) {
        reactionGroups = groups
    }

    /// The users a row mentions, empty when it mentions none — handed to the row's
    /// resolver so `@`-tokens resolve from the message's own data.
    func mentions(for id: String) -> [MentionRef] {
        mentionRefs[id].map { Array($0) } ?? []
    }

    /// Reads mentions for `ids` off the main actor. `store` is immutable, so this is
    /// safe to call from the `nonisolated` observation loop.
    nonisolated func fetchMentions(for ids: [String]) -> [String: MentionRefList] {
        (try? store.mentions(for: ids)) ?? [:]
    }

    func applyMentions(_ mentions: [String: MentionRefList]) {
        mentionRefs = mentions
    }

    /// Sends a reaction on a message through the durable send path — an ordinary
    /// persisted kind-7, not an ephemeral.
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

    /// Toggles a chip: withdraws the local identity's own reaction (a kind-5 naming
    /// it) when it is highlighted, otherwise adds that emoji.
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

    /// Drops an own pending or failed row — the context-menu "delete".
    func delete(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.discard(eventID) }
    }
}
