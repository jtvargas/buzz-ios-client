import BuzzKit
import SwiftUI

/// A channel's timeline: newest at the bottom, older pages loaded at the top by
/// keyset cursor, day separators between local days, and a floating composer with the
/// "who is typing" strip above it. Messages carry reaction chips, and a long press opens
/// ``MessageActionsSheet``; a threaded message opens its thread. Reads are live from the
/// store; presence and typing are live from the engine's ``PresenceStore``; the composer
/// sends and signals typing through it.
///
/// The list, the header's placement, the bar, and the keyboard/safe-area arithmetic all
/// belong to ``ConversationScaffold`` — this view supplies the four slots and nothing
/// else, so a thread and a DM inherit the same behaviour for free.
struct ChannelTimelineView: View {
    @State private var model: ChannelTimelineModel
    @State private var presence: PresenceModel
    @State private var typing: ChannelTypingModel
    @State private var access: ChannelAccessModel
    @State private var showsChannelDetails = false
    /// Whether the roster sheet is open — the `person.3.fill` beside the `⋮`.
    @State private var showsPeople = false
    /// The message whose actions sheet is open, if any — set by a long press on a row.
    @State private var messageActions: MessageActionTarget?
    /// Whose profile is open, if anyone's — set by a tap on a row's avatar or name.
    @State private var profilePeer: ProfilePeer?
    /// The chip whose reactor list is open, if any — set by a hold on a reaction.
    @State private var reactionReactors: ReactionReactorsTarget?
    /// Whether a join started from the bar is on the wire. Local to the surface that
    /// offers it: the *outcome* is read from the store like everything else, and this is
    /// only the in-flight moment between the tap and the roster commit.
    @State private var isJoining = false
    @Environment(\.entityNames) private var names
    @Environment(\.pushRoute) private var pushRoute
    /// Optional, and that is what makes this surface mountable outside the app graph.
    ///
    /// The non-optional form traps in `EnvironmentBox.update` when nothing has been put in
    /// the environment — before any `body` runs, so it is not reachable by guarding the one
    /// call site below. ``ConversationFixtureHost`` mounts this view directly, so every
    /// conversation UI shape has crashed on launch since this property was added; the suite is
    /// not a pull-request gate, so nothing said so.
    @Environment(AppEnvironment.self) private var appEnvironment: AppEnvironment?
    private let channel: ChannelListRow
    private let channelID: String
    private let store: BuzzEventStore
    /// The three collaborators this view's own `body` needs, named rather than reached for
    /// through a `SyncEngine`. Typing and read-state are handed to the model and not kept
    /// here, because nothing below reads them.
    ///
    /// `presenceStore` backs the channel-details sheet.
    /// Fills in this channel's threads, once, on arrival. Optional for the reason given on
    /// ``ThreadPrefetching``.
    private let prefetcher: (any ThreadPrefetching)?
    private let presenceStore: PresenceStore
    private let uploader: MediaUploaderProvider
    private let lifecycleEngine: SyncEngine?
    private let selfPubkey: String?
    /// Whether the composer takes the keyboard once this conversation has settled. Set
    /// only by the Drafts screen — see ``SwiftUI/View/focusesComposerOnArrival(_:focus:)``.
    private let focusesComposer: Bool
    /// The people this conversation was opened with, when it was reached by opening a direct
    /// message rather than from the sidebar. Only ever consulted while the roster has
    /// nothing to say — see ``EntityNames/conversation(for:knownPeers:)``.
    private let knownPeers: [String]
    /// One message this conversation was opened *at*, when it was reached from search. The
    /// screen still opens at its newest message and this is walked back to from there — see
    /// ``ChannelTimelineModel/focus(on:sentAt:)``.
    private let focus: ConversationFocus?

    /// The link to the message this screen was opened at, for the reach panel to offer when
    /// it could not get there.
    ///
    /// No thread root: this path is the one where the message's own threading is exactly what
    /// is not known — a reply this device holds would have opened its thread from the search
    /// results instead of arriving here. The link resolves without it.
    private var reachLinkURL: URL? {
        guard let focus else { return nil }
        return MessageLink.url(
            channelID: channelID, messageID: focus.messageID, threadRootID: nil
        )
    }

    /// Reserved for the top-of-history sentinel. Constant, and present whenever an
    /// older page may exist: a spinner that appears and disappears is itself a content
    /// height change at the top of a bottom-anchored list, which is one visible jump
    /// per page loaded.
    private static let topSentinelHeight: CGFloat = 44

    /// The production initialiser: the engine is every collaborator below.
    init(
        channel: ChannelListRow,
        store: BuzzEventStore,
        engine: SyncEngine,
        drafts: ComposerDrafts? = nil,
        uploader: @escaping MediaUploaderProvider,
        selfPubkey: String?,
        knownPeers: [String] = [],
        focusingComposer focusesComposer: Bool = false,
        focusing focus: ConversationFocus? = nil
    ) {
        self.init(
            channel: channel,
            store: store,
            sender: engine,
            typing: engine,
            readStateMarking: engine,
            history: engine,
            opener: engine,
            prefetcher: engine,
            presence: engine.presenceStore,
            drafts: drafts,
            uploader: uploader,
            selfPubkey: selfPubkey,
            knownPeers: knownPeers,
            lifecycleEngine: engine,
            focusingComposer: focusesComposer,
            focusing: focus
        )
    }

    /// The same view with its collaborators named.
    ///
    /// ``ChannelTimelineModel`` was always written against `MessageSending`,
    /// `EphemeralPublishing` and `ReadStateMarking`; only this initialiser reached for the
    /// concrete engine, and a `SyncEngine` cannot exist without a relay socket. That put the
    /// scroll surface out of reach of a UI test, so the thirteen shapes that found the
    /// `#49`/`#50`/`#52` defects lived outside the repo, gated nothing, and exercised a
    /// *copy* of this screen that was free to drift from it.
    ///
    /// This initialiser exists so a test drives **this** view. It adds no behaviour.
    init(
        channel: ChannelListRow,
        store: BuzzEventStore,
        sender: any MessageSending,
        typing: any EphemeralPublishing,
        readStateMarking: (any ReadStateMarking)?,
        history: (any ChannelHistoryPaging)? = nil,
        opener: any ThreadOpening,
        prefetcher: (any ThreadPrefetching)? = nil,
        presence: PresenceStore,
        drafts: ComposerDrafts? = nil,
        uploader: @escaping MediaUploaderProvider,
        selfPubkey: String?,
        knownPeers: [String] = [],
        lifecycleEngine: SyncEngine? = nil,
        focusingComposer focusesComposer: Bool = false,
        focusing focus: ConversationFocus? = nil
    ) {
        self.focusesComposer = focusesComposer
        self.focus = focus
        self.channel = channel
        channelID = channel.id
        self.store = store
        self.prefetcher = prefetcher
        presenceStore = presence
        self.uploader = uploader
        self.lifecycleEngine = lifecycleEngine
        self.selfPubkey = selfPubkey
        self.knownPeers = knownPeers
        _model = State(initialValue: ChannelTimelineModel(
            channel: channel.id,
            store: store,
            sender: sender,
            typing: typing,
            readStateMarking: readStateMarking,
            history: history,
            drafts: drafts,
            uploader: uploader,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presence))
        _typing = State(initialValue: ChannelTypingModel(
            channel: channel.id,
            store: presence,
            selfPubkey: selfPubkey
        ))
        _access = State(initialValue: ChannelAccessModel(
            channelID: channel.id,
            identity: selfPubkey,
            store: store
        ))
    }

    var body: some View {
        // Page one is read here rather than in `init` (see `primeIfNeeded()`): a `body`
        // runs before layout, so the bottom anchor still resolves against real content,
        // while a view struct SwiftUI initialises and discards — which is every one of
        // them but the first, on every commit — costs an allocation instead of three
        // blocking store reads on the main actor.
        model.primeIfNeeded()

        return ConversationScaffold(
            // A hand-written binding rather than `$model.isAtBottom`: a binding
            // projected through `State` of an observable class writes the reference
            // back into `State` on every set, which would invalidate this whole view
            // on each scroll threshold crossing.
            isAtBottom: Binding(get: { model.isAtBottom }, set: { model.isAtBottom = $0 }),
            isFarFromBottom: Binding(
                get: { model.jump.isFarFromBottom },
                set: { model.jump.setFarFromBottom($0) }
            ),
            jumpToken: model.jumpToken,
            jumpTarget: model.jumpTarget,
            contentRevision: model.contentRevision,
            rowRevision: model.rowRevision,
            newestID: model.items.newestMessageID,
            composerRevision: model.attachments.barRevision,
            onReachedTop: loadOlderPage,
            onLeavingScreen: releaseComposer
        ) {
            list
        } bar: {
            bar
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        // Above the conversation and below nothing: the reach is the only thing on this
        // screen the reader is waiting on, and it has controls they have to be able to hit.
        // Hit testing is off for everything but the panel — see ``MessageReachPanel``.
        .overlay {
            MessageReachPanel(
                seek: model.jump.seek,
                onCancel: { model.cancelFocus() },
                onRetry: { model.retryFocus() },
                onCopyLink: reachLinkURL.map { url in
                    {
                        UIPasteboard.general.string = url.absoluteString
                        HiveHaptics.play(.suggestionPicked)
                        // Copying answers the report, so it takes it away — pressing a control
                        // and being left looking at the same failure reads as the press not
                        // having landed.
                        model.cancelFocus()
                    }
                }
            )
        }
        .focusesComposerOnArrival(focusesComposer) { model.mentionAutocomplete.isComposerFocused = true }
        .modifier(header)
        // A conversation takes the whole screen. The tab bar is not just visual clutter
        // under the composer: it is a second bottom inset, and every scroll and keyboard
        // decision this surface makes is arithmetic over that inset — so a conversation
        // reads exactly as it did before there were tabs.
        //
        // That is declared by the view that owns the stack, and deliberately not here:
        // `.toolbar(.hidden, for: .tabBar)` on this view left the screen underneath at the
        // wrong bottom inset for ~530ms after the pop, with its rows 49pt low, and then they
        // snapped up. See ``ChannelListView/hidesTabBar`` for the traces.
        .sheet(isPresented: $showsChannelDetails) {
            ChannelDetailsView(
                channel: channel,
                store: store,
                presenceStore: presenceStore,
                engine: lifecycleEngine,
                selfPubkey: selfPubkey
            )
        }
        .sheet(isPresented: $showsPeople) {
            ConversationPeopleSheet(
                channel: channelID,
                store: store,
                presenceStore: presenceStore
            )
        }
        // The same modifier a thread uses, so the two surfaces cannot present a
        // different profile sheet for the same tap.
        .profileSheet(peer: $profilePeer, presence: presence)
        // Likewise the reactor list, from the same hold on a chip. Tapping somebody in it
        // hands back a pubkey once that sheet has closed, and it opens the *same* profile
        // sheet an avatar in the timeline opens — the reader's own tap on a name and their
        // tap on a reactor cannot show two different things.
        .reactionReactorsSheet(
            target: $reactionReactors,
            store: store,
            presenceStore: presenceStore,
            selfPubkey: selfPubkey,
            onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
        )
        // Likewise the same actions sheet, from the same long press. The channel is the
        // surface that offers "Reply in thread", because it is the one with a thread to
        // push — and that reply is a request to *write*, so the composer takes the keyboard
        // on arrival.
        .messageActionsSheet(
            target: $messageActions,
            actions: model,
            isReadOnly: !access.allowsInteraction,
            onReplyInThread: { open(thread: $0, focusingComposer: true) },
            onRemind: { row, due in
                // Nothing to schedule against outside the app graph — a fixture has no store
                // of reminders and no session to own them.
                guard let appEnvironment else { return }
                Task {
                    await ReminderCreation.set(
                        row,
                        channelID: channelID,
                        due: due,
                        authorName: names.name(for: row.pubkey),
                        in: appEnvironment
                    )
                }
            }
        )
        .task { await model.run() }
        // After the first render, never from the prime: the reach ends in a `jumpToken` bump,
        // and a bump made before the scaffold has installed its `onChange` is a change that
        // observer never sees — see ``ChannelTimelineModel/focus(on:sentAt:)``.
        //
        // Started rather than awaited: the reader can cancel it and run it again, so no one
        // attempt is the answer. What it *finds* comes back through `focusThreadRoot` below.
        .task { if let focus { model.startFocus(focus) } }
        .onDisappear {
            model.cancelFocus()
            // The sidebar and the Activity feed are what this screen going away reveals, and
            // they are the only two things that render read state — so this is where the
            // engine's coalescing window has to land. See ``ChannelTimelineModel/flushReadMarks()``.
            model.flushReadMarks()
        }
        // A message that turns out to be a thread reply is only discoverable once the reach
        // has been past its place in history and stored it — see
        // ``ChannelTimelineModel/FocusOutcome/inThread(root:)``. The other endings have
        // already said what they had to say on the surface itself.
        .onChange(of: model.focusThreadRoot) { _, root in
            guard let root, let focus else { return }
            pushRoute?(.thread(ThreadRoute(
                root: root, channel: channelID, anchor: .reply(focus.messageID)
            )))
        }
        .task { await presence.run() }
        // Here rather than inside ``TypingIndicatorView``, which is absent from the view
        // tree until somebody is typing and so could never start its own model — see the
        // note on that type. The surface that owns the model runs it, as above.
        .task { await typing.run() }
        .task { await access.run() }
        // This channel's threads only. A message row's reply *count* needs no replies
        // (the relay's tally supplies it), but the faces on its replies strip are read from
        // the replies themselves, so on a cold launch a row would otherwise say "3 replies"
        // over an empty strip. See ``BuzzKit/SyncEngine/prefetchThreads(in:)``.
        .task { await prefetcher?.prefetchThreads(in: channelID) }
        // Which conversation is on screen, with two effects
        // (§ ``BuzzKit/SyncEngine/setActiveChannel(_:)``): a reconnect — which is most of
        // what foregrounding the app does — restores *this* channel's live subscription
        // before the other joined channels'; and a channel with no standing subscription —
        // one opened without being a member, as Browse allows — gets one registered plus a
        // head reconcile, which is this screen's only relay path.
        // Not cleared when the view goes away: the engine's preference is advisory, and
        // the channel just left is the one most likely to be opened again.
        .task { await lifecycleEngine?.setActiveChannel(channelID) }
    }

    /// How this conversation presents itself — a channel, or the person on the other
    /// end of a two-member roster. Computed rather than captured in `init` because the
    /// resolver arrives from the environment — and because capturing it there is what let
    /// a DM read as its group name and an unnamed channel render its whole group id (§4).
    ///
    /// `knownPeers` covers exactly one gap: a DM opened seconds ago whose membership has not
    /// been projected yet, where the roster cannot classify the conversation and the header
    /// would otherwise read `Untitled conversation`. The roster wins the moment it lands.
    private var conversation: ConversationIdentity {
        names.conversation(for: channel, knownPeers: knownPeers)
    }

    // MARK: - List

    private var list: some View {
        // The spacing inside one author's block, as the list's own spacing rather than as
        // padding on each row: a row's height stays its content's height. Everything that
        // starts something — a new block, a day, a notice — pays the rest of the 12pt gap
        // itself, below. See ``MessageRowMetrics``.
        // Newest first, and every row flipped back — the two halves the inverted scroll view
        // needs from its owner. See ``View/conversationInverted()``.
        LazyVStack(spacing: MessageRowMetrics.withinGroup) {
            // Day separators and the grouping of consecutive messages are both items, not
            // row headers, so the channel, a thread, and a DM cannot each grow their own
            // copy of either rule. Grouped once per rows change in the model; this pass is
            // a read.
            //
            // Reversed here rather than in the model: grouping is chronological — which row
            // opens a block, where a day starts — and reversing before it would ask those
            // rules to read backwards. The model stays oldest-first and only the drawing
            // order turns around.
            ForEach(model.items.reversed()) { item in
                itemView(item)
                    // `.bottom`, not `.top`: the gap belongs above the row that opens a block,
                    // and this stack is drawn upside down.
                    .padding(.bottom, item.continuesGroup ? 0 : MessageRowMetrics.aboveNewGroup)
                    .conversationInverted()
            }
            // Last, because the far end of a flipped stack is the top of history.
            topSentinel
                .conversationInverted()
        }
        .padding(.vertical, 8)
        .dismissesSuggestionsOnScroll(model.mentionAutocomplete)
    }

    /// The fixed slot at the top of history: always ``topSentinelHeight`` tall, whatever
    /// it happens to be saying, because a slot that appears and disappears is itself a
    /// content-height change at the top of a bottom-anchored list.
    ///
    /// It says one of three things: older history is on its way, the last reach for it
    /// failed, or this is where the channel begins.
    ///
    /// The spinner is bound to "there is more above" and deliberately **not** to
    /// ``ChannelTimelineModel/isLoadingOlder``, which is invisible by construction: the
    /// scaffold reports the top a whole viewport early
    /// (``ConversationScaffold/topTrigger``, 800pt), so the fetch it triggers starts and
    /// finishes while this slot is still 800 points above the visible rect. A reader who
    /// then scrolls up to look at it arrives after the flag has cleared and sees an empty
    /// gap — which is what the paging feels like when nothing marks it.
    ///
    /// The objection to an unconditional spinner was that it cannot be told apart from a
    /// stuck one, and that was fair while nothing could satisfy it. It resolves now:
    /// exhaustion is latched on the relay's own answer, so the spinner ends in the
    /// beginning-of-conversation line, and a failed reach replaces it with a retry rather
    /// than spinning over it.
    ///
    /// ``ChannelTimelineModel/hasReachedForOlder`` is the other half of that answer, and
    /// without it the objection was right after all — in exactly the conversations where the
    /// slot can be seen. "There is more above" is true from the first commit of any
    /// non-empty conversation, but the fetch that would settle it only runs once the reader
    /// has taken hold of the list, and a conversation that fits on one screen gives them no
    /// reason to. So this slot sat on screen spinning for a fetch nobody had asked for and
    /// nothing was going to start; it looked stuck because it *was*. The long conversations
    /// hid it, since the slot is a whole viewport above the visible rect until scrolling
    /// brings it down, by which time paging is live and the spinner means what it says.
    @ViewBuilder
    private var topSentinel: some View {
        if model.olderFailed {
            Button(action: loadOlderPage) {
                Label("Couldn't load older messages. Tap to retry.", systemImage: "arrow.clockwise")
                    .font(.hive(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(height: Self.topSentinelHeight)
        } else if model.hasMoreOlder, model.hasReachedForOlder {
            ProgressView()
                .frame(height: Self.topSentinelHeight)
                .accessibilityLabel("Loading older messages")
        } else if model.hasReachedBeginning, !model.rows.isEmpty {
            Text("This is the beginning of the conversation")
                .font(.hive(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: Self.topSentinelHeight)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded, model.rows.isEmpty {
            ContentUnavailableView(
                "No messages yet",
                systemImage: "text.bubble",
                description: Text("Say hello below.")
            )
        }
    }

    /// The heading, in the navigation bar's leading slot beside the system back button: the
    /// conversation's mark, its name, and its member count beneath. See
    /// ``ConversationTitleBar``.
    ///
    /// It opens the details sheet on tap. No dropdown arrow: a sheet is not a menu, so a
    /// chevron promising one is the wrong affordance, and the bar's own capsule already
    /// reads as a control.
    private var header: ConversationTitleBar {
        // Resolved once for both lines and the accessibility label, rather than four times
        // through the directory on every pass.
        let identity = conversation
        return ConversationTitleBar(
            mark: ConversationTitleBar.mark(for: identity),
            title: identity.title,
            subtitle: subtitle(for: identity),
            action: { showsChannelDetails = true },
            actionHint: "Double tap to show conversation details",
            manageAction: { showsChannelDetails = true },
            // Withheld from a one-to-one direct message: the heading there is already the
            // person and their presence dot, so a button that would list the two of you is
            // a control whose only answer is what the reader is looking at.
            peopleAction: identity.isOneToOne ? nil : { showsPeople = true }
        )
    }

    /// The header's second line: who is in this channel and how many of them are here now,
    /// or — for a direct message — whether the person on the other end is.
    ///
    /// `2 members` under a person's name is a category error: a direct message *is* a
    /// two-member roster, so the number restates the fact that this is a DM. Their presence
    /// is the part that changes, and it is read from the same ``PresenceModel`` the message
    /// rows' dots are, so the header and a row cannot disagree about the same person.
    ///
    /// The roster and the presence roster arrive asynchronously and independently, so both
    /// branches may legitimately have nothing to say yet; the pill then draws one line.
    private func subtitle(for conversation: ConversationIdentity) -> ConversationTitleBar.Subtitle? {
        if let peer = conversation.peer {
            return .presence(presence.isOnline(peer))
        }
        let members = names.members(of: channelID)
        return ConversationTitleBar.memberCount(
            members.count,
            online: members.count(where: { presence.isOnline($0) })
        )
        .map(ConversationTitleBar.Subtitle.text)
    }

}

/// The list's two element builders and the four small things the body reaches for. In an
/// extension rather than the struct itself — the house style ``ChannelListView`` already
/// follows — so the type reads as its state and its slots, and the helpers sit under them.
private extension ChannelTimelineView {
    /// One rendered conversation element. The `switch` is the whole of the surface's
    /// content policy: everything that decides *which* elements there are, and which of
    /// them continue a block, belongs to ``ConversationGrouping``.
    @ViewBuilder
    func itemView(_ item: ConversationItem) -> some View {
        switch item {
        case let .day(marker):
            DaySeparatorView(date: marker.date)
        case let .message(row, continuesGroup):
            messageRow(row, continuesGroup: continuesGroup)
        case let .notice(marker):
            SystemNoticeRowView(notice: marker.notice, alsoJoined: marker.alsoJoined, date: marker.date)
        }
    }

    /// One message. `continuesGroup` is the only thing this surface does with the grouping:
    /// a row that continues a block does not name its author again.
    func messageRow(_ row: TimelineRow, continuesGroup: Bool) -> some View {
        TimelineRowView(
            row: row,
            showsAuthorHeader: !continuesGroup,
            isAuthorOnline: presence.isOnline(row.pubkey),
            reactions: model.reactions(for: row.id),
            mentions: model.mentions(for: row.id),
            replyParticipants: model.participants(for: row.id),
            selfPubkey: selfPubkey,
            allowsInteraction: access.allowsInteraction,
            onRetry: { model.retry($0) },
            onReact: { model.react($0, on: row.id) },
            onToggleReaction: { model.toggleReaction($0, on: row.id) },
            onOpenThread: row.isDeleted ? nil : { open(thread: row) },
            onLongPress: {
                messageActions = MessageActionTarget(
                    row: row,
                    isOwn: model.isOwn(row),
                    channelID: channelID,
                    threadRootID: nil
                )
            },
            onLongPressReaction: { reactionReactors = ReactionReactorsTarget(
                messageID: row.id,
                emoji: $0.emoji
            ) },
            onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) },
            conversation: conversation
        )
        // The shared constant, not a bare `.padding(.horizontal)`: the day separator starts
        // on this same line, and two defaults agreeing is not the same as one number.
        .padding(.horizontal, MessageRowMetrics.rowLeading)
        // Outside the padding, so the wash runs the full width of the row rather than
        // stopping where the text does. See ``View/messageFocusHighlight(_:)``.
        .messageFocusHighlight(model.highlightedMessageID == row.id)
    }

    /// The scaffold's "the top of history is near" report. It arrives as a level
    /// rather than an edge and can fire several times across one page load, which the
    /// model's own guard absorbs.
    func loadOlderPage() {
        Task { await model.loadOlder() }
    }

    /// The scaffold's "this surface is leaving the screen" report: drop the composer's
    /// focus and its suggestion panel, so a keyboard raised for this channel cannot
    /// outlive it into a thread — or be restored under it on the way back. The scaffold
    /// has already resigned the responder; this is the observed half of the same state.
    func releaseComposer() {
        model.mentionAutocomplete.dismissComposer()
    }

    /// Opens the thread a row belongs to: its own id when it is the opener, its
    /// root when it is a (broadcast) reply.
    ///
    /// `focusingComposer` is set only by the actions sheet's "Reply in thread". The row's own
    /// tap and its replies strip are someone going to *read*, and raising a keyboard over
    /// what they came to read is the wrong answer to both.
    func open(thread row: TimelineRow, focusingComposer: Bool = false) {
        let root = row.rootID ?? row.id
        _ = ConversationKeyboardResignation.resignActiveResponder()
        pushRoute?(.thread(ThreadRoute(
            root: root,
            channel: channelID,
            focusesComposer: focusingComposer
        )))
    }

    /// A typer's name, through the injected directory — the same answer the sidebar,
    /// a message row, and a mention give. It replaces a scan of the loaded rows, which
    /// could only name someone who had already spoken in the page on screen.
    func authorName(_ pubkey: String) -> String {
        names.name(for: pubkey)
    }

    /// What floats over the list just above the composer: the jump affordances, and the
    /// mention suggestion panel.
    var accessory: some View {
        // A local `Bindable` rather than `$model`, for the same reason the `isAtBottom`
        // binding is hand-written above.
        @Bindable var model = model
        return VStack(spacing: 8) {
            ChannelAccessBanner(state: access.state)
            // `model.jump` is a `let`, so reading it here registers no dependency: the
            // count is read inside ``ConversationJumpControls``, and an arrival that
            // moves it invalidates that view alone rather than this body and its list.
            ConversationJumpControls(
                state: model.jump,
                onJumpToNew: { model.jumpToNewMessages() },
                onJumpToLatest: { model.jumpToLatest() }
            )
            MentionSuggestionsView(
                document: $model.mentionDraft,
                autocomplete: model.mentionAutocomplete
            )
            // Last, so it sits closest to the composer — the thing it is about — and so
            // the suggestion panel, which is the taller and more urgent of the two,
            // grows upwards away from it rather than pushing it off the bar.
            TypingIndicatorView(model: typing, nameFor: authorName)
            // Beneath the typing strip, in the same capsule: while the connection is
            // down nobody's typing can reach us anyway, so the two are near-exclusive,
            // and this is the one that explains the silence. It reads the engine state
            // itself rather than taking it as a parameter, so a transition invalidates
            // this one small view instead of the whole surface and its list.
            ConnectionStatusIndicatorView()
        }
    }

    /// What stands at the bottom of the conversation — one thing at a time.
    ///
    /// The composer alone, historically. The typing pill was here, stacked above it, and
    /// the bar's height *is* the list's bottom inset — so somebody starting to type
    /// re-inset the conversation and moved the reader. It is an accessory now, and the
    /// join bar keeps out of the same trap by replacing the composer rather than sitting
    /// over it.
    @ViewBuilder
    var bar: some View {
        switch access.participation {
        case .allowed, .readOnly:
            // `.readOnly` is byte-identical to today deliberately. An archived channel is
            // already non-writable through `isWritable`, and the accessory's
            // ``ChannelAccessBanner`` already says so in words — a second sentence down
            // here would be the same explanation twice on one screen. What the case buys
            // is the ordering above it: archived resolves here and never to
            // `.joinRequired`, so this surface cannot offer a Join the relay refuses.
            ComposerView(model: model)
                .disabled(!access.isWritable)
        case .joinRequired:
            ChannelJoinBar(
                name: conversation.title,
                isJoining: isJoining,
                // Withheld rather than handed over and guarded inside, the same as the
                // thread's. `joinThisChannel` can only no-op without an engine, and a
                // button that no-ops is the one thing ``ChannelJoinBar`` documents it will
                // not draw. Production always has one, so this is the fixture host.
                join: lifecycleEngine.map { _ in joinThisChannel }
            )
        }
    }

    /// Joins the channel being read, from the bar, without leaving it.
    ///
    /// Nothing is assigned on success: the join commits the roster before it returns, and
    /// ``ChannelAccessModel`` is already watching for that commit — so the bar becomes a
    /// composer through the same live read every other participation decision comes from,
    /// rather than through a second piece of state here that could disagree with it.
    ///
    /// The in-flight guard is the browser's (``BrowseChannelsModel/join(_:)``): the button
    /// disables, but a double tap can land before the first assignment paints.
    ///
    /// A failure is deliberately silent. There is no error surface in the bar and the two
    /// refusals that can reach it are both already prevented — an archived channel resolves
    /// `.readOnly` and never offers this, and a private one resolves `.allowed`. What is
    /// left is a dropped socket, where the bar simply stays and the button is live again.
    func joinThisChannel() {
        guard !isJoining, let lifecycleEngine else { return }
        isJoining = true
        Task {
            defer { isJoining = false }
            try? await lifecycleEngine.joinChannel(channelID) { _ in }
        }
    }
}
