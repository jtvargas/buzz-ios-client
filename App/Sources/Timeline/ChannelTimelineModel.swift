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
    /// frozen boundary and later arrivals are counted in ``jump`` instead.
    /// Pagination reads the full loaded set, never this.
    private(set) var rows: [TimelineRow] = []
    /// ``rows`` with day separators interleaved — computed once per rows change
    /// rather than per render pass, since a list touches its items several times in
    /// one layout.
    private(set) var items: [ConversationItem] = []
    /// Bumped whenever the *item set* changes — rows arriving, an older page inserted, a row
    /// pruned. ``ConversationScaffold`` restores the reader's place across the settling that
    /// follows one of these and across nothing else: a `LazyVStack` re-measures unchanged
    /// content whenever the container moves, so its height cannot stand in for this.
    private(set) var contentRevision = 0
    /// Bumped when something drawn *inside* a row changes its height without changing the item
    /// set — a reaction chip, a resolved mention, a reply summary. These used to bump
    /// ``contentRevision``, which is the reported jump on reacting to an older message: one
    /// channel could not say which of the two had happened.
    private(set) var rowRevision = 0
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
    /// Whether a page is being fetched right now. Meaningful only since paging
    /// learned to leave the device: while ``loadOlder()`` was a pure local read it was
    /// set and cleared inside one MainActor turn and no frame was ever drawn with it
    /// `true`, which is why the sentinel used to ignore it.
    private(set) var isLoadingOlder = false
    /// Whether the last reach for older history failed.
    ///
    /// Its own state rather than a silent `false` on ``hasMoreOlder``: a spinner cannot
    /// say whether it is waiting on the network or on nothing at all, and folding the
    /// failure into "exhausted" is what ends scrollback for the life of a screen with
    /// nothing on it to retry.
    private(set) var olderFailed = false
    /// Whether the reader has reached for older history in this conversation yet.
    ///
    /// Not the same fact as ``isLoadingOlder``, and it exists because ``hasMoreOlder`` is
    /// not evidence of anything happening. With a relay pager, `mayHaveOlder` answers
    /// `!loaded.isEmpty` — every non-empty conversation offers paging until the relay
    /// itself says otherwise — so "there is more above" is true from the first commit and
    /// stays true whether or not anybody is fetching.
    ///
    /// What closes the gap is that the fetch is deliberately gated on the reader having
    /// taken hold of the list (`ConversationScaffold`, `place.hasMoved`): reaching for
    /// history is a gesture, and a page that lands before one has been made snaps a reader
    /// to the newest message under their own thumb. So in a conversation short enough to
    /// need no scrolling, nothing ever asks — and a sentinel bound to ``hasMoreOlder``
    /// alone sat there spinning for a fetch that was never going to start.
    private(set) var hasReachedForOlder = false

    /// The composer's wire text plus identity-bearing selected mention tokens. Every
    /// change is written through to this channel's draft — see
    /// `ChannelTimelineModel+Drafts.swift`, which is also where the `didSet` is explained.
    var mentionDraft = MentionDraft() { didSet { recordDraft(replacing: oldValue) } }
    /// Where that draft is kept between visits. `nil` in tests, which then keep nothing.
    let drafts: ComposerDrafts?
    let mentionAutocomplete: MentionAutocompleteModel
    /// The pictures the composer is carrying, prepared locally as they are picked and
    /// cleared by the send that names them. Per-model, so a thread opened from this
    /// channel keeps its own.
    let attachments: ComposerAttachmentsModel
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

    /// An own send that has been queued but has not appeared on screen yet — the row the next
    /// rebuild has to land the author on. See ``landOnOwnSend(among:)``.
    ///
    /// Not observable: nothing renders it, and the moment it clears already bumps
    /// ``jumpToken``, which is what the scaffold watches.
    @ObservationIgnored var awaitingOwnSend: String?

    /// What the affordances above the composer show: how many arrivals the freeze holds
    /// back, which one to land on, and whether the newest row is far enough below to
    /// offer a way back. Held apart from the rows on purpose — see ``ConversationJumpState``.
    let jump = ConversationJumpState()

    /// Bumped to ask the scaffold to scroll: the reader tapping one of the affordances,
    /// or an own send that would otherwise land out of sight. Settable across the module
    /// rather than `private(set)` for the reason the collaborators below are internal —
    /// the jumps that bump it are in `ChannelTimelineModel+Jump.swift`.
    var jumpToken = 0
    /// Where that bump lands.
    var jumpTarget: ConversationJumpTarget = .bottom

    /// The message to mark as *the one you came here for*, or `nil` when there is none.
    ///
    /// Observable, and read by the row that matches it — so it invalidates the list twice
    /// per arrival, which is what it costs to say something about one row from outside it.
    /// That is affordable here and would not be if it changed per frame: it is set once
    /// when a landing happens and cleared once a moment later.
    ///
    /// What draws it is a background, never anything that occupies space. A highlight that
    /// changed a row's height would move the reader by the growth of every row the stack
    /// re-estimates around it — the defect ``ConversationReaderPlace/rowDidChangeInPlace()``
    /// exists to absorb, arriving here as a *new* one at the exact moment the reader has
    /// just been taken somewhere.
    /// Settable across the module for ``jumpToken``'s reason: what sets it is the landing,
    /// and the landings live in `ChannelTimelineModel+Jump.swift`.
    var highlightedMessageID: String?
    /// Clears the highlight after its moment. Internal rather than `private` for the reason
    /// the collaborators below are — `private` is file-scoped, and the jumps live in
    /// `ChannelTimelineModel+Jump.swift`. Not observable: nothing renders it.
    @ObservationIgnored var highlightTask: Task<Void, Never>?

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
    ///
    /// Internal like its neighbours above, so ``markReadIfNeeded()`` can read it from
    /// `ChannelTimelineModel+ReadState.swift`: a `private` member is reachable only from
    /// the file that declares it.
    let readStateMarking: (any ReadStateMarking)?
    /// Where older history comes from once the local store runs out. `nil` — the
    /// fixtures and the UI tests — keeps the old behaviour: page what is on the
    /// device, then stop.
    let history: (any ChannelHistoryPaging)?
    /// Internal for the same reason, so ``fetch(before:)`` can read it from
    /// `ChannelTimelineModel+Live.swift`. Immutable, so widening it exposes no mutation.
    let pageSize: Int
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
    ///
    /// `private(set)` rather than `private` so the id sets derived from it can sit beside
    /// their only reader in `+Rows.swift`. Writes stay confined to this file, which is the
    /// invariant that matters: what is loaded changes only through the head merge, the
    /// prune, and paging.
    private(set) var loaded: [String: TimelineRow] = [:]
    /// The oldest loaded row's cursor, the basis of the next older page. Tracks the
    /// *full* loaded set, so a frozen tail never affects where pagination resumes.
    ///
    /// `private(set)` rather than `private` because the walk in `+Jump.swift` reads it to
    /// know when it has gone past the message it is looking for — Swift's `private` is
    /// file-scoped. Writes stay here, with the rebuild that derives it.
    private(set) var earliest: TimelineCursor?
    /// Set once history is proved to end above the oldest loaded row, and no later head
    /// re-read may re-open it. The proof is the relay's exhaustion fact, or — with no
    /// relay pager — a short local page.
    private var hasExhaustedOlder = false

    /// Whether the oldest loaded row is the first thing this channel ever held, proved
    /// rather than assumed. What the surface draws the top of the conversation on: a
    /// channel that has simply not paged yet claims no beginning.
    var hasReachedBeginning: Bool { hasExhaustedOlder }
    /// The boundary behind which arrivals are held while the reader reads history.
    /// Internal because the jump that releases it lives beside this file.
    var tail = TimelineTail()

    /// Whether ``primeIfNeeded()`` has already read page one. Not observable: nothing
    /// reads it, and it is written from inside a `body`.
    @ObservationIgnored private var hasPrimed = false

    /// The newest rendered `created_at` this view has already marked read, so a scroll
    /// back through older history (which never changes the newest rendered row) re-marks
    /// nothing and only a genuinely newer *viewable* message advances the frontier.
    ///
    /// Written from `ChannelTimelineModel+ReadState.swift` and nowhere else.
    @ObservationIgnored var lastMarkedReadAt: Int64 = 0

    init(
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        typing: any EphemeralPublishing = NoopEphemeralPublisher(),
        readStateMarking: (any ReadStateMarking)? = nil,
        history: (any ChannelHistoryPaging)? = nil,
        drafts: ComposerDrafts? = nil,
        uploader: @escaping MediaUploaderProvider = { nil },
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
        self.history = history
        self.drafts = drafts
        self.selfPubkey = selfPubkey
        self.pageSize = pageSize
        self.typingThrottle = typingThrottle
        self.clock = clock
        attachments = ComposerAttachmentsModel(uploader: uploader)
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
        restoreDraft()
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

    // MARK: - Merging what the live read returns

    /// Merges the newest page into the loaded set and returns every loaded row id,
    /// so the caller can re-read reactions for exactly what is on screen.
    ///
    /// `refreshed` carries re-read copies of rows outside the head window. They update
    /// in place and never insert: the head is the only authority on what has stopped
    /// existing, and it does not cover these rows — so a row the by-id read no longer
    /// returns is left alone rather than dropped. Applied after ``prune(against:)`` so a
    /// row the head *has* retired cannot be resurrected by its own refresh.
    @discardableResult
    func mergeHead(_ head: [TimelineRow], refreshing refreshed: [TimelineRow] = []) -> [String] {
        prune(against: head)
        for row in refreshed where loaded[row.id] != nil { loaded[row.id] = row }
        for row in head { loaded[row.id] = row }
        rebuild()
        // Guarded like the rest: written on every commit, read in the timeline's `body`.
        if !hasLoaded { hasLoaded = true }
        // Re-derived on every head re-read, not only the first, because a channel opened
        // before its backfill lands starts with a short head and must still offer
        // pagination once the backfill fills it — but never re-opened once history has
        // been proved exhausted.
        if !hasExhaustedOlder, hasMoreOlder != mayHaveOlder(head) {
            hasMoreOlder = mayHaveOlder(head)
        }
        return Array(loaded.keys)
    }

    /// Whether to offer paging above the loaded set.
    ///
    /// Without a relay pager this is the local read's own evidence: a full head page
    /// means there is more underneath it, and a short one means there is not.
    ///
    /// With one, that evidence is worthless in both directions. A short head is exactly
    /// what an interrupted or degraded backfill leaves — the channel it could not finish
    /// has *most* of its history above the floor, and reading the shortfall as
    /// "exhausted" is what stranded a reader at whatever depth the background reconcile
    /// happened to reach. So paging stays on offer until the relay itself says the
    /// channel is out of history (``hasExhaustedOlder``). The emptiness check is only to
    /// keep a channel with nothing in it from advertising history above nothing.
    private func mayHaveOlder(_ head: [TimelineRow]) -> Bool {
        history != nil ? !loaded.isEmpty : head.count >= pageSize
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

    /// Loads the page immediately older than the oldest loaded row: from the local
    /// store first, via the `(createdAt, id)` keyset cursor — never an offset — and
    /// from the relay when the store has nothing more to give.
    ///
    /// Idempotent while a load is in flight and once history is exhausted, because the
    /// scaffold reports the top threshold as a level rather than an edge and can report
    /// it repeatedly across one load. That guard now matters more than it did: each
    /// report past the local floor can cost a round trip.
    ///
    /// Exhaustion is latched on one thing only — the relay saying there is nothing
    /// older. A short local page is where the *device* runs out, which is not the same
    /// fact and was being treated as if it were.
    func loadOlder() async {
        // Ahead of the guard, because this records the *reach* and not the fetch. The
        // scaffold only calls here once the reader has taken hold of the list, so the first
        // call is the moment paging becomes a thing that happens — even on the passes the
        // guard turns away, which are the repeat reports of one level crossing.
        if !hasReachedForOlder { hasReachedForOlder = true }
        guard hasMoreOlder, !isLoadingOlder, let cursor = earliest else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        if olderFailed { olderFailed = false }

        lastOlderCursor = cursor
        let older = fetch(before: cursor)
        apply(older: older)
        guard older.count < pageSize else { return }

        // The device is out of history at this cursor. Without somewhere to ask, that
        // is the end of it — the pre-relay behaviour, kept for the fixtures.
        guard let history else {
            hasExhaustedOlder = true
            hasMoreOlder = false
            return
        }

        // Keeps going while the relay has more and the reader has been given nothing to
        // see. A window page can legitimately land no rows on this screen — the cursor
        // chain re-walks the boundary second, and a reconcile running underneath can have
        // filled the stretch it asks for — and returning after one of those leaves the
        // surface exactly as it was: no new rows, no height change, and so nothing for the
        // scaffold to report a top with again. One page per report was the whole budget,
        // and a page that spent it on duplicates ended scrollback silently.
        //
        // Bounded, because the alternative is walking a whole channel inside one report.
        // Running out of budget is not exhaustion: ``hasMoreOlder`` stays true and the
        // next report resumes where the cursor chain stands.
        for _ in 0 ..< Self.olderPageBudget {
            let loadedBefore = loaded.count
            do {
                let page = try await history.loadOlderHistory(
                    channel: channel,
                    before: WindowCursor(createdAt: cursor.createdAt, id: cursor.id)
                )
                // Only a page that wrote something can have moved the local floor. Re-read
                // from the same cursor: what it just ingested is, by construction, below
                // it — and the cursor is still the floor on every pass that gets here,
                // because the first pass to move it returns.
                if page.ingested > 0 { apply(older: fetch(before: cursor)) }
                if !page.hasMore {
                    hasExhaustedOlder = true
                    hasMoreOlder = false
                    return
                }
                guard loaded.count == loadedBefore else { return }
            } catch {
                // Deliberately not latched: the channel is not out of history, this attempt
                // failed. ``hasMoreOlder`` stays true so the sentinel can offer a retry.
                olderFailed = true
                return
            }
        }
    }

    /// How many window pages one ``loadOlder()`` may walk while none of them puts a row
    /// on screen. Enough to carry the cursor past a crowded boundary second or a stretch
    /// a background reconcile has already filled; small enough that the reader is never
    /// waiting on an unbounded walk.
    /// Internal rather than `private` so the walk's own test can say what it means by "did
    /// not stop at the first stall" in terms of this number, instead of a magic one that
    /// silently stops testing anything if this moves.
    static let olderPageBudget = 5

    /// How many pages ``focus(on:)`` may walk back looking for one message. At the page
    /// size that is a couple of thousand messages, which is far more history than a search
    /// result has ever sat behind in this app and still a bound rather than a promise —
    /// the walk can cost a relay round trip per page once it passes what the device holds.
    ///
    /// A backstop rather than the terminator: the walk normally stops the moment it passes
    /// the message's own place in history, which it can only do because the caller supplies
    /// the timestamp. Running this out is reported as ``ConversationSeekFailure/unreachable``
    /// and never as "not found", because it proves nothing about the message.
    ///
    /// Internal, not `private`: the walk is in `ChannelTimelineModel+Jump.swift`, and
    /// Swift's `private` is file-scoped.
    static let focusPageBudget = 40
    /// How many passes in a row may bring nothing back before ``focus(on:sentAt:)`` gives up.
    ///
    /// Not one. ``loadOlder()`` returns having loaded nothing in three situations that are
    /// **not** the end of history, all of them ordinary: another caller's load was already in
    /// flight and this one was turned away at the guard; its own relay budget went on window
    /// pages that landed only rows already held, which is what a crowded boundary second
    /// looks like; or a page failed and it left ``olderFailed`` set for a retry. Treating the
    /// first stall as exhaustion is what ended the walk early and reported a message that was
    /// there as missing.
    static let focusStallBudget = 4
    /// The thread the message this screen was opened at turned out to live in, once the reach
    /// has proved it is not on this surface — see ``FocusOutcome/inThread(root:)``.
    ///
    /// A property rather than the walk's return value because the walk can be cancelled and
    /// run again, and the caller that pushes the thread is a `.task` that must not be left
    /// awaiting any one attempt.
    var focusThreadRoot: String?
    /// The message the reach is for, kept so **Try again** has something to ask for.
    @ObservationIgnored var focusRequest: ConversationFocus?
    /// The supervised reach itself. Not observable: nothing draws it — ``jump`` carries what
    /// the surface says about it.
    @ObservationIgnored var focusTask: Task<Void, Never>?

    /// How long ``focus(on:sentAt:)`` may keep a reader waiting before it stops and says so.
    ///
    /// The page budget is not a bound on *time*: every page past what the device holds is a
    /// relay round trip, and ``loadOlder()`` may spend five of them on one page, so the
    /// budget alone permits a walk of a minute or more. Nothing about a message is worth
    /// that much of a reader's attention when the alternative is telling them plainly that
    /// it could not be reached — which is honest, and leaves them where they can act.
    ///
    /// Generous against what a walk actually costs: the local pages that carry most of them
    /// are a millisecond each, so this is spent almost entirely on a relay that is being
    /// slow, which is exactly the case it exists to end.
    static let focusDeadline = Duration.seconds(15)
    /// How long the walk waits before re-asking after a pass that brought nothing back.
    ///
    /// Long enough for an in-flight local page to land and for a failed relay page not to be
    /// re-asked instantly; short enough that four of them are still under a second of a
    /// reader's time on top of the reading itself.
    static let focusStallPause = Duration.milliseconds(200)
    /// How close a landing has to be, in rows, to be worth animating.
    ///
    /// About two screens of ordinary messages. Beyond it the travel renders every row it
    /// passes over and reads as a stutter rather than as a journey — the reasoning is with
    /// ``ConversationJumpTarget/message(_:animated:)``, and the reason it is a row count
    /// rather than a distance is that rows are the only quantity here that is not estimated.
    static let animatedLandingRows = 25

    /// Merges an older page into the loaded set and brings its reactions, mentions and
    /// reply participants with it — immediately, rather than waiting on the next commit
    /// signal, so a scroll back never shows chip-less or unresolved history.
    private func apply(older: [TimelineRow]) {
        guard !older.isEmpty else { return }
        for row in older { loaded[row.id] = row }
        rebuild()
        let ids = Array(loaded.keys)
        applyReactions(fetchReactions(for: ids))
        applyMentions(fetchMentions(for: ids))
        applyThreadParticipants(fetchThreadParticipants(for: threadedRowIDs))
    }

    /// Re-derives everything downstream of the loaded set: the pagination cursor from
    /// the *full* set, then the rendered rows, their grouped items, and the read
    /// frontier from whatever the tail lets through.
    func rebuild() {
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
        // Written only when they change. An `@Observable` property notifies on every set,
        // equal or not — so an arrival held behind the freeze, which renders exactly what
        // was already rendered, would still invalidate the list it was held back from.
        if rows != split.rendered { rows = split.rendered }
        let grouped = ConversationGrouping.items(for: split.rendered)
        if items != grouped {
            // Which of the two revisions this is: ``[ConversationItem]/isStructuralChange(to:)``.
            let isStructural = items.isStructuralChange(to: grouped)
            items = grouped
            if isStructural { contentRevision += 1 } else { rowRevision += 1 }
        }
        jump.hold(count: split.held.count, firstID: split.held.first?.id)
        landOnOwnSend(among: split.rendered)
        markReadIfNeeded()
    }

    // MARK: - Applying reads

    // Both setters live here rather than beside their readers because `private(set)`
    // is file-scoped: only this file may write them. Each guards against writing back an
    // equal value, for the reason ``rebuild()`` records — all three are re-read on every
    // commit the store raises, including commits that change nothing a reader can see.

    func applyReactions(_ groups: [String: [ReactionGroup]]) {
        if reactionGroups != groups {
            reactionGroups = groups
            rowRevision += 1
        }
    }

    func applyMentions(_ mentions: [String: MentionRefList]) {
        if mentionRefs != mentions {
            mentionRefs = mentions
            rowRevision += 1
        }
    }

    func applyThreadParticipants(_ participants: [String: ThreadParticipants]) {
        if replyParticipants != participants {
            replyParticipants = participants
            rowRevision += 1
        }
    }
}
