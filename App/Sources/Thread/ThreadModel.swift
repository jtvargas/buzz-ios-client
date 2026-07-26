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
@MainActor
@Observable
final class ThreadModel {
    /// The thread's root (opener) id.
    let root: String
    /// The channel the thread lives in, for the reply's `h` scope and send routing.
    let channel: String

    private(set) var rows: [TimelineRow] = []
    /// Surviving reaction groups per row, re-read on the same observation as `rows`.
    private(set) var reactionGroups: [String: [ReactionGroup]] = [:]
    /// The users each row mentions, keyed by message id, re-read on the same
    /// observation as `rows` so `@`-tokens resolve from each message's own `p` tags.
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    private(set) var hasLoaded = false

    /// The reply composer's text. Cleared optimistically on send.
    var draft: String = ""
    /// Set when a reply is refused before it leaves the device (over the 64 KiB
    /// ceiling); the view shows it and the draft text is preserved.
    var sendError: String?

    private let store: BuzzEventStore
    private let sender: any MessageSending
    private let opener: any ThreadOpening
    /// The local identity's hex pubkey, for own-reaction highlighting and delete.
    let selfPubkey: String?

    init(
        root: String,
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        opener: any ThreadOpening,
        selfPubkey: String?
    ) {
        self.root = root
        self.channel = channel
        self.store = store
        self.sender = sender
        self.opener = opener
        self.selfPubkey = selfPubkey
    }

    // MARK: - Open + observe

    /// Renders the thread from the local store immediately, pulling the thread from
    /// the relay in parallel, then consumes the observation until cancelled. Attach
    /// with SwiftUI's `.task`.
    ///
    /// Observation and the one-shot fetch run concurrently — the fetch never gates
    /// the first render. Gating it did: the thread laid out empty and only filled
    /// after a relay round-trip, so ``ThreadView``'s `.defaultScrollAnchor(.bottom)`
    /// anchored against empty content and left a gap under the newest message. Read
    /// first, the observation's initial emission renders the opener (and any already
    /// ingested replies) on the first frame — exactly as the channel timeline does —
    /// and the fetch's replies merge in live as they land.
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
        rows = thread
        hasLoaded = true
        return thread.map(\.id)
    }

    // MARK: - Reply

    /// Sends the reply draft, threaded to the root. Optimistic and fire-and-forget:
    /// the pending reply appears through the observation the moment the outbox row
    /// commits. An over-ceiling reply throws before it is queued — the text is
    /// restored and surfaced.
    func sendReply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sendError = nil

        let channel = self.channel
        let root = self.root
        let sender = self.sender
        Task { [weak self] in
            do {
                try await sender.enqueue(
                    kind: .channelMessage,
                    content: text,
                    in: channel,
                    tags: OutboundTags.reply(channel: channel, root: root, parent: root),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
            } catch let error as OutboxError {
                await self?.restore(draft: text, error: error)
            } catch {
                // A transient send failure leaves the reply queued for the next drain.
            }
        }
    }

    private func restore(draft text: String, error: OutboxError) {
        if draft.isEmpty { draft = text }
        sendError = Self.describe(error)
    }

    private static func describe(_ error: OutboxError) -> String {
        switch error {
        case let .contentTooLarge(bytes, limit):
            "Reply is too large (\(bytes) bytes; limit \(limit))."
        case .invalidEvent, .notQueued, .encodingFailed:
            "Couldn't send that reply."
        }
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
        reactionGroups = groups
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
        mentionRefs = mentions
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
