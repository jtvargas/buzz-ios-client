import BuzzKit
import Foundation
import GRDB
import NostrCore
import Observation

/// Drives ``ChannelTimelineView`` for one channel: a live head observation, keyset
/// pagination of older history, and the rendered tail's freeze while the reader is not
/// at the bottom. The outbound half — send, retry, typing — lives in
/// `ChannelTimelineModel+Sending.swift`, and the per-row reads and actions in
/// `ChannelTimelineModel+Rows.swift`.
///
/// Rows are held ascending (oldest first) so the view can anchor to the bottom and
/// render newest-last. The live observation re-reads the newest page on every
/// relevant commit; older pages are loaded on demand and merged by id, so an edit,
/// a deletion, or a `pending → sent` transition updates the *same* row in place
/// rather than appearing twice.
///
/// Page one is read synchronously on the first `body` pass — see ``primeIfNeeded()`` —
/// so the first layout has real content to anchor against instead of an empty stack.
@MainActor
@Observable
final class ChannelTimelineModel {
    let channel: String

    /// The messages to render, ascending by `(createdAt, id)` — the total order the
    /// keyset query pages on, so "newest" means the same thing here and in the DB.
    /// The *rendered* set: while the reader is away from the bottom it stops at the
    /// frozen boundary and later arrivals are counted in ``heldBackCount`` instead.
    /// Pagination reads the full loaded set, never this.
    private(set) var rows: [TimelineRow] = []
    /// ``rows`` with day separators interleaved — computed once per rows change
    /// rather than per render pass, since a list touches its items several times in
    /// one layout.
    private(set) var items: [ConversationItem] = []
    /// Surviving reaction groups for each loaded row, keyed by message id. Re-read
    /// on the same observation as the rows, so a react, a withdrawal, or a peer's
    /// reaction updates the chips live without a second pipeline.
    private(set) var reactionGroups: [String: [ReactionGroup]] = [:]
    /// The users each loaded row mentions, keyed by message id, resolved from each
    /// message's own `p` tags. Re-read on the same observation as the rows, so a
    /// mentioned user's profile landing updates the rendered name live (WS-1 #9).
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    /// The distinct repliers behind each threaded row's reply preview, keyed by the
    /// thread's root id. Re-read on the same observation as the rows, so a face appears
    /// the moment the reply that put it there is ingested — and read for the whole page
    /// at once (see ``threadedRowIDs``) rather than a query per row.
    private(set) var replyParticipants: [String: ThreadParticipants] = [:]
    private(set) var hasLoaded = false
    /// Whether an older page may still exist before the oldest loaded row.
    private(set) var hasMoreOlder = false
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

    // MARK: - Scroll position

    /// Whether the newest row is in view. Written by ``ConversationScaffold`` from
    /// scroll geometry; leaving the bottom freezes the rendered tail so an arriving
    /// message cannot move the reader's place, and returning releases it.
    var isAtBottom = true {
        didSet {
            guard isAtBottom != oldValue else { return }
            // `rows` is the whole loaded set here: leaving the bottom means the tail was
            // released, so the rendered set and the loaded set are the same list, and it
            // carries the boundary second's own membership.
            if isAtBottom { tail.release() } else { tail.freeze(at: rows.last, among: rows) }
            rebuild()
        }
    }

    /// How many arrivals the frozen tail is holding back — the count behind the
    /// "N new messages" affordance, and `0` whenever nothing is held.
    private(set) var heldBackCount = 0

    /// Bumped to ask the scaffold to scroll to the newest row: the reader tapping the
    /// "N new messages" pill, or an own send that would otherwise land out of sight —
    /// see ``jumpToLatestIfNeeded()``.
    private(set) var jumpToken = 0

    /// Releases the frozen tail, renders everything loaded, and asks the view to
    /// scroll to the newest row.
    ///
    /// The freeze is exactly the inverse of ``isAtBottom``, so setting that releases
    /// it — asserted, not waited for. The scaffold's geometry callback confirms the
    /// position a frame later and re-freezes if the scroll did not land.
    func jumpToLatest() {
        isAtBottom = true
        jumpToken += 1
    }

    /// The `before` cursor most recently handed to `store.timeline(before:)`. A
    /// test seam: it is exactly the keyset position paged from, proving pagination
    /// never falls back to offset paging (spec §Step 1 tests).
    private(set) var lastOlderCursor: TimelineCursor?

    /// Internal rather than private because the model's collaborators live beside it:
    /// the per-row reads and actions in `ChannelTimelineModel+Rows.swift`, and the send /
    /// retry / typing path in `ChannelTimelineModel+Sending.swift`. Swift's `private` is
    /// file-scoped, and one 550-line model file is worse than a three-file split.
    let store: BuzzEventStore
    let sender: any MessageSending
    let typing: any EphemeralPublishing
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
    let typingThrottle: Duration
    /// The monotonic clock the throttle measures against, injected so a test drives
    /// the throttle window without real time.
    let clock: @Sendable () -> ContinuousClock.Instant
    /// When own typing was last published, for the throttle. Not observable: nothing
    /// renders it, so publishing it would only invalidate readers per keystroke.
    @ObservationIgnored var lastTypingPublish: ContinuousClock.Instant?

    /// Loaded rows keyed by id, so a re-read of the head merges into — rather than
    /// duplicates — rows an older page already holds.
    private var loaded: [String: TimelineRow] = [:]
    /// The oldest loaded row's cursor, the basis of the next older page. Tracks the
    /// *full* loaded set, so a frozen tail never affects where pagination resumes.
    private var earliest: TimelineCursor?
    /// Set once an older page comes back short: history is exhausted before the
    /// oldest loaded row, and no later head re-read may re-open it.
    private var hasExhaustedOlder = false
    /// The boundary behind which arrivals are held while the reader reads history.
    private var tail = TimelineTail()

    /// Whether ``primeIfNeeded()`` has already read page one. Not observable: nothing
    /// reads it, and it is written from inside a `body`.
    @ObservationIgnored private var hasPrimed = false

    /// The newest rendered `created_at` this view has already marked read, so a scroll
    /// back through older history (which never changes the newest rendered row) re-marks
    /// nothing and only a genuinely newer *viewable* message advances the frontier.
    @ObservationIgnored private var lastMarkedReadAt: Int64 = 0

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

    /// Reads page one, its reactions, and its mentions synchronously — once.
    ///
    /// Called from the top of ``ChannelTimelineView``'s `body`, not from `init`.
    /// `State(initialValue:)` evaluates its argument every time the view struct is
    /// initialised, and a pushed destination's view struct is re-initialised whenever
    /// the pushing view's body re-evaluates — which, for a live channel list, is on
    /// every database commit. Priming in `init` therefore ran three blocking SQLite
    /// reads on the main actor per commit for an object SwiftUI immediately discarded;
    /// a discarded instance never runs a `body`, so it now costs an allocation.
    ///
    /// Deliberately not `.task`: that runs *after* first layout, and reading
    /// synchronously is what lets the scroll view's bottom anchor resolve against real
    /// content height instead of an empty stack. `body` runs before layout, so the
    /// pre-layout guarantee is preserved.
    ///
    /// Three local reads on the concurrent reader; no relay round trip, no `await`,
    /// and nothing here can fail loudly — an unreadable store simply leaves the
    /// surface in the state the observation will fill a moment later.
    func primeIfNeeded() {
        guard !hasPrimed else { return }
        hasPrimed = true
        mergeHead(fetch(before: nil))
        let ids = Array(loaded.keys)
        applyReactions(fetchReactions(for: ids))
        applyMentions(fetchMentions(for: ids))
        applyThreadParticipants(fetchThreadParticipants(for: threadedRowIDs))
    }

    /// The loaded rows that advertise a thread — the only ids the participants read has
    /// anything to return for.
    ///
    /// Narrowed rather than passing the whole page: a channel where one message in twenty
    /// has replies would otherwise send fifty ids into an `IN` list to get two rows back,
    /// on every commit.
    var threadedRowIDs: [String] {
        loaded.values.filter(\.hasThread).map(\.id)
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
                // Merging rebuilds the rendered set, which is also what marks the
                // channel read up to the newest row the reader can actually see.
                let ids = await mergeHead(head)
                // Same signal, same reader, off the main actor: re-read reactions and
                // mentions for every loaded row so chips and @-tokens track the
                // timeline exactly.
                let groups = fetchReactions(for: ids)
                await applyReactions(groups)
                let mentions = fetchMentions(for: ids)
                await applyMentions(mentions)
                // Only the threaded rows, and only after the merge that decided which
                // rows those are — a reply landing is exactly the commit that turns a
                // plain row into a threaded one.
                let roots = await threadedRowIDs
                let participants = fetchThreadParticipants(for: roots)
                await applyThreadParticipants(participants)
            }
        } catch {
            // Ends on cancellation or teardown; last snapshot stays on screen.
        }
    }

    /// Marks the channel read up to the newest *rendered* message, once per advance —
    /// mark-on-view. Fires the moment the channel opens and again whenever a newer
    /// message becomes viewable while the view is up; a scroll back through older
    /// history leaves the newest rendered row unchanged, so it re-marks nothing.
    ///
    /// The newest *rendered* row, not the newest loaded one. While the tail is frozen
    /// the reader can see nothing past the boundary, and the NIP-RS frontier is
    /// grow-only and shared with every other device — so advancing it past held-back
    /// arrivals is not recoverable: the pill said "3 new messages" while the sidebar row
    /// for the same channel dropped to zero unread and un-bolded, and backing out lost
    /// the marker everywhere.
    ///
    /// Called from ``rebuild()``, so it tracks the rendered set for any reason it
    /// advances — an arrival, the channel opening, an older page, or the freeze
    /// releasing — and the `lastMarkedReadAt` guard makes every redundant call free.
    ///
    /// Fire-and-forget so the observation loop never blocks on the publish, and
    /// grow-only on the engine side so a redundant call is a no-op.
    private func markReadIfNeeded() {
        guard let readStateMarking,
              let newest = rows.last?.createdAt, newest > lastMarkedReadAt else { return }
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
        prune(against: head)
        for row in head { loaded[row.id] = row }
        rebuild()
        hasLoaded = true
        // A full head page means older history may exist. Re-derived on every head
        // re-read, not only the first, because a channel opened before its backfill
        // lands starts with a short head and must still offer pagination once the
        // backfill fills it — but never re-opened once an older page came back short,
        // the one durable proof that history is exhausted.
        if !hasExhaustedOlder {
            hasMoreOlder = head.count >= pageSize
        }
        return Array(loaded.keys)
    }

    /// Drops loaded rows the head has stopped returning.
    ///
    /// The head is the newest page in the `(createdAt, id)` total order, so any loaded
    /// row at or newer than the head's own oldest row would have to be *in* it — unless
    /// it has stopped being visible. Merging by id alone could only ever add, so
    /// discarding an own pending send left it on screen until the channel was reopened,
    /// and the frozen tail then counted a row that no longer exists.
    ///
    /// Rows strictly older than the head's floor came from an older page and are outside
    /// the head's window, so the head says nothing about them and they are kept.
    ///
    /// Only ever prunes against a head that returned something: ``fetch(before:)`` folds
    /// a read failure into an empty page, and reading that as "the channel is empty"
    /// would blank a timeline the store merely failed to read this once.
    private func prune(against head: [TimelineRow]) {
        // The page's floor is its *oldest* row, and `timeline(channel:before:limit:)`
        // returns newest-first — so reading `head.first` put the floor at the newest row
        // instead, which made this guard nearly a no-op: almost every loaded row compared
        // as older than it and survived, and only a ghost newer than the entire page was
        // ever dropped. `min` says what is meant without depending on the query's order.
        guard let floor = head.min(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) else { return }
        let returned = Set(head.map(\.id))
        loaded = loaded.filter { _, row in
            returned.contains(row.id) || (row.createdAt, row.id) < (floor.createdAt, floor.id)
        }
    }

    // MARK: - Pagination

    /// Loads the page immediately older than the oldest loaded row, via the
    /// `(createdAt, id)` keyset cursor — never an offset. Idempotent while a load
    /// is in flight and once history is exhausted, because the scaffold reports the
    /// top threshold as a level rather than an edge and can report it repeatedly
    /// across one load.
    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, let cursor = earliest else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        lastOlderCursor = cursor
        let older = fetch(before: cursor)
        for row in older { loaded[row.id] = row }
        rebuild()
        if older.count < pageSize {
            hasExhaustedOlder = true
            hasMoreOlder = false
        }
        // Bring in the older rows' reactions and mentions immediately rather than
        // waiting on the next commit signal, so a scroll back never shows chip-less
        // or unresolved history.
        let ids = Array(loaded.keys)
        applyReactions(fetchReactions(for: ids))
        applyMentions(fetchMentions(for: ids))
        applyThreadParticipants(fetchThreadParticipants(for: threadedRowIDs))
    }

    /// Re-derives everything downstream of the loaded set: the pagination cursor from
    /// the *full* set, then the rendered rows, their grouped items, and the read
    /// frontier from whatever the tail lets through.
    private func rebuild() {
        let ordered = loaded.values.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
        }
        earliest = ordered.first.map(TimelineCursor.init(row:))

        // An empty conversation has no row to freeze at, so a reader who left the bottom
        // of one armed nothing — and `isAtBottom` has no `false → false` transition to
        // recover on, so without this every arrival from then on moved their place. The
        // first content to appear while they are still away becomes the boundary: it
        // renders (there was nothing to hold it back), and everything after it is held.
        if !isAtBottom, !tail.isFrozen, let newest = ordered.last {
            tail.freeze(at: newest, among: ordered)
        }

        let split = tail.split(ordered)
        rows = split.rendered
        heldBackCount = split.heldBack
        items = ConversationGrouping.items(for: split.rendered)
        markReadIfNeeded()
    }

    // MARK: - Applying reads

    // Both setters live here rather than beside their readers because `private(set)`
    // is file-scoped: only this file may write them.

    func applyReactions(_ groups: [String: [ReactionGroup]]) {
        reactionGroups = groups
    }

    func applyMentions(_ mentions: [String: MentionRefList]) {
        mentionRefs = mentions
    }

    func applyThreadParticipants(_ participants: [String: ThreadParticipants]) {
        replyParticipants = participants
    }
}
