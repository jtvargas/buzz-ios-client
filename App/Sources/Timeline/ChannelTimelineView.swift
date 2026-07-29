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
    @State private var openedThread: ThreadRoute?
    @State private var showsChannelDetails = false
    /// The message whose actions sheet is open, if any — set by a long press on a row.
    @State private var messageActions: MessageActionTarget?
    /// Whose profile is open, if anyone's — set by a tap on a row's avatar or name.
    @State private var profilePeer: ProfilePeer?
    @Environment(\.entityNames) private var names
    private let channel: ChannelListRow
    private let channelID: String
    private let store: BuzzEventStore
    /// The three collaborators this view's own `body` needs, named rather than reached for
    /// through a `SyncEngine`. Typing and read-state are handed to the model and not kept
    /// here, because nothing below reads them.
    ///
    /// `sender` and `opener` are carried so a thread pushed from a row is built with the same
    /// collaborators as this screen; `presenceStore` backs the channel-details sheet.
    private let sender: any MessageSending
    private let opener: any ThreadOpening
    private let presenceStore: PresenceStore
    private let selfPubkey: String?
    /// The peer this conversation was opened with, when it was reached by opening a direct
    /// message rather than from the sidebar. Only ever consulted while the roster has
    /// nothing to say — see ``EntityNames/conversation(for:knownPeer:)``.
    private let knownPeer: String?

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
        selfPubkey: String?,
        knownPeer: String? = nil
    ) {
        self.init(
            channel: channel,
            store: store,
            sender: engine,
            typing: engine,
            readStateMarking: engine,
            opener: engine,
            presence: engine.presenceStore,
            selfPubkey: selfPubkey,
            knownPeer: knownPeer
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
        opener: any ThreadOpening,
        presence: PresenceStore,
        selfPubkey: String?,
        knownPeer: String? = nil
    ) {
        self.channel = channel
        channelID = channel.id
        self.store = store
        self.sender = sender
        self.opener = opener
        presenceStore = presence
        self.selfPubkey = selfPubkey
        self.knownPeer = knownPeer
        _model = State(initialValue: ChannelTimelineModel(
            channel: channel.id,
            store: store,
            sender: sender,
            typing: typing,
            readStateMarking: readStateMarking,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presence))
        _typing = State(initialValue: ChannelTypingModel(
            channel: channel.id,
            store: presence,
            selfPubkey: selfPubkey
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
            jumpToken: model.jumpToken,
            jumpTarget: model.jumpTarget,
            contentRevision: model.contentRevision,
            newestID: model.items.newestMessageID,
            onReachedTop: loadOlderPage,
            onLeavingScreen: releaseComposer
        ) {
            list
        } bar: {
            // The composer alone. The typing pill was here, stacked above it, and the
            // bar's height is the list's bottom inset — so somebody starting to type
            // re-inset the conversation and moved the reader. It is an accessory now.
            ComposerView(model: model)
        } accessory: {
            accessory
        }
        .overlay { emptyState }
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
                presenceStore: presenceStore
            )
        }
        // The same modifier a thread uses, so the two surfaces cannot present a
        // different profile sheet for the same tap.
        .profileSheet(peer: $profilePeer, presence: presence)
        // Likewise the same actions sheet, from the same long press. The channel is the
        // surface that offers "Reply in thread", because it is the one with a thread to
        // push — and that reply is a request to *write*, so the composer takes the keyboard
        // on arrival.
        .messageActionsSheet(
            target: $messageActions,
            actions: model,
            onReplyInThread: { open(thread: $0, focusingComposer: true) }
        )
        .navigationDestination(item: $openedThread) { route in
            ThreadView(
                root: route.root,
                channel: route.channel,
                store: store,
                sender: sender,
                opener: opener,
                presence: presenceStore,
                selfPubkey: selfPubkey,
                focusingComposer: route.focusesComposer
            )
        }
        .task { await model.run() }
        .task { await presence.run() }
    }

    /// How this conversation presents itself — a channel, or the person on the other
    /// end of a two-member roster. Computed rather than captured in `init` because the
    /// resolver arrives from the environment — and because capturing it there is what let
    /// a DM read as its group name and an unnamed channel render its whole group id (§4).
    ///
    /// `knownPeer` covers exactly one gap: a DM opened seconds ago whose membership has not
    /// been projected yet, where the roster cannot classify the conversation and the header
    /// would otherwise read `Untitled conversation`. The roster wins the moment it lands.
    private var conversation: ConversationIdentity {
        names.conversation(for: channel, knownPeer: knownPeer)
    }

    // MARK: - List

    private var list: some View {
        // 12pt between messages, as the list's own spacing rather than as padding on
        // each row: one number owns the rhythm, and a row's height stays its content's
        // height. See ``MessageRowMetrics``.
        LazyVStack(spacing: MessageRowMetrics.betweenMessages) {
            topSentinel
            // Day separators are items, not row headers, so the channel, a thread, and
            // a DM cannot each grow their own copy of the grouping rule. Grouped once
            // per rows change in the model; this pass is a read.
            ForEach(model.items) { item in
                switch item {
                case let .day(marker):
                    DaySeparatorView(date: marker.date)
                case let .message(row):
                    messageRow(row)
                case let .notice(marker):
                    SystemNoticeRowView(notice: marker.notice)
                }
            }
        }
        .padding(.vertical, 8)
        .dismissesSuggestionsOnScroll(model.mentionAutocomplete)
    }

    /// The fixed slot at the top of history: always ``topSentinelHeight`` tall, and
    /// spinning, for exactly as long as an older page may exist.
    ///
    /// It stands for "there is more above", not for "a load is in flight". Binding its
    /// opacity to `isLoadingOlder` looked like the honest thing and was in fact dead:
    /// `loadOlder()` has no suspension point, so the flag is set and cleared inside one
    /// MainActor turn and no frame is ever drawn with it `true`. The model keeps the flag
    /// as its re-entrancy guard, where it does real work.
    @ViewBuilder
    private var topSentinel: some View {
        if model.hasMoreOlder {
            ProgressView()
                .frame(height: Self.topSentinelHeight)
                .accessibilityHidden(true)
        }
    }

    private func messageRow(_ row: TimelineRow) -> some View {
        TimelineRowView(
            row: row,
            isAuthorOnline: presence.isOnline(row.pubkey),
            reactions: model.reactions(for: row.id),
            mentions: model.mentions(for: row.id),
            replyParticipants: model.participants(for: row.id),
            selfPubkey: selfPubkey,
            onRetry: { model.retry($0) },
            onReact: { model.react($0, on: row.id) },
            onToggleReaction: { model.toggleReaction($0, on: row.id) },
            onOpenThread: row.isDeleted ? nil : { open(thread: row) },
            onLongPress: { messageActions = MessageActionTarget(row: row, isOwn: model.isOwn(row)) },
            onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
        )
        // The shared constant, not a bare `.padding(.horizontal)`: the day separator starts
        // on this same line, and two defaults agreeing is not the same as one number.
        .padding(.horizontal, MessageRowMetrics.rowLeading)
    }

    /// What floats over the list just above the composer: the jump affordances, and the
    /// mention suggestion panel.
    private var accessory: some View {
        // A local `Bindable` rather than `$model`, for the same reason the `isAtBottom`
        // binding is hand-written above.
        @Bindable var model = model
        return VStack(spacing: 8) {
            // `model.jump` is a `let`, so reading it here registers no dependency: the
            // count is read inside ``ConversationJumpControls``, and an arrival that
            // moves it invalidates that view alone rather than this body and its list.
            ConversationJumpControls(
                state: model.jump,
                onJumpToNew: { model.jumpToNewMessages() }
            )
            MentionSuggestionsView(
                document: $model.mentionDraft,
                autocomplete: model.mentionAutocomplete
            )
            // Last, so it sits closest to the composer — the thing it is about — and so
            // the suggestion panel, which is the taller and more urgent of the two,
            // grows upwards away from it rather than pushing it off the bar.
            TypingIndicatorView(model: typing, nameFor: authorName)
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
            actionHint: "Double tap to show conversation details"
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

    /// The scaffold's "the top of history is near" report. It arrives as a level
    /// rather than an edge and can fire several times across one page load, which the
    /// model's own guard absorbs.
    private func loadOlderPage() {
        Task { await model.loadOlder() }
    }

    /// The scaffold's "this surface is leaving the screen" report: drop the composer's
    /// focus and its suggestion panel, so a keyboard raised for this channel cannot
    /// outlive it into a thread — or be restored under it on the way back. The scaffold
    /// has already resigned the responder; this is the observed half of the same state.
    private func releaseComposer() {
        model.mentionAutocomplete.dismissComposer()
    }

    /// Opens the thread a row belongs to: its own id when it is the opener, its
    /// root when it is a (broadcast) reply.
    ///
    /// `focusingComposer` is set only by the actions sheet's "Reply in thread". The row's own
    /// tap and its replies strip are someone going to *read*, and raising a keyboard over
    /// what they came to read is the wrong answer to both.
    private func open(thread row: TimelineRow, focusingComposer: Bool = false) {
        let root = row.rootID ?? row.id
        openedThread = ThreadRoute(root: root, channel: channelID, focusesComposer: focusingComposer)
    }

    /// A typer's name, through the injected directory — the same answer the sidebar,
    /// a message row, and a mention give. It replaces a scan of the loaded rows, which
    /// could only name someone who had already spoken in the page on screen.
    private func authorName(_ pubkey: String) -> String {
        names.name(for: pubkey)
    }
}
