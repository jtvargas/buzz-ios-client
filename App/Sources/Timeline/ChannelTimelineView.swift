import BuzzKit
import SwiftUI

/// A channel's timeline: newest at the bottom, older pages loaded at the top by
/// keyset cursor, day separators between local days, and a floating composer with the
/// "who is typing" strip above it. Messages carry reaction chips and a long-press menu
/// (react, copy, and retry/delete on own pending/failed rows); a threaded message
/// opens its thread. Reads are live from the store; presence and typing are live from
/// the engine's ``PresenceStore``; the composer sends and signals typing through it.
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
    /// Whose profile is open, if anyone's — set by a tap on a row's avatar or name.
    @State private var profilePeer: ProfilePeer?
    @Environment(\.entityNames) private var names
    private let channel: ChannelListRow
    private let channelID: String
    private let store: BuzzEventStore
    private let engine: SyncEngine
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

    init(
        channel: ChannelListRow,
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        knownPeer: String? = nil
    ) {
        self.channel = channel
        channelID = channel.id
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        self.knownPeer = knownPeer
        let presenceStore = engine.presenceStore
        _model = State(initialValue: ChannelTimelineModel(
            channel: channel.id,
            store: store,
            sender: engine,
            typing: engine,
            readStateMarking: engine,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presenceStore))
        _typing = State(initialValue: ChannelTypingModel(
            channel: channel.id,
            store: presenceStore,
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
            onReachedTop: loadOlderPage,
            onLeavingScreen: releaseComposer
        ) {
            list
        } bar: {
            // One bottom bar, not two insets: stacked safe-area insets place the
            // last-applied one closest to the screen edge, which would put the typing
            // strip *below* the composer.
            VStack(spacing: 4) {
                TypingIndicatorView(model: typing, nameFor: authorName)
                ComposerView(model: model)
            }
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        .modifier(header)
        .sheet(isPresented: $showsChannelDetails) {
            ChannelDetailsView(
                channel: channel,
                store: store,
                presenceStore: engine.presenceStore
            )
        }
        // The same modifier a thread uses, so the two surfaces cannot present a
        // different profile sheet for the same tap.
        .profileSheet(peer: $profilePeer, presence: presence)
        .navigationDestination(item: $openedThread) { route in
            ThreadView(
                root: route.root,
                channel: route.channel,
                store: store,
                engine: engine,
                selfPubkey: selfPubkey
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
            isOwn: model.isOwn(row),
            onRetry: { model.retry($0) },
            onReact: { model.react($0, on: row.id) },
            onToggleReaction: { model.toggleReaction($0, on: row.id) },
            onDelete: { model.delete($0) },
            onOpenThread: row.isDeleted ? nil : { open(thread: row) },
            onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
        )
        // The shared constant, not a bare `.padding(.horizontal)`: the day separator starts
        // on this same line, and two defaults agreeing is not the same as one number.
        .padding(.horizontal, MessageRowMetrics.rowLeading)
    }

    /// What floats over the list just above the composer: the held-back arrivals
    /// affordance, and the mention suggestion panel.
    private var accessory: some View {
        // A local `Bindable` rather than `$model`, for the same reason the `isAtBottom`
        // binding is hand-written above.
        @Bindable var model = model
        return VStack(spacing: 8) {
            if model.heldBackCount > 0 {
                NewMessagesPill(count: model.heldBackCount) {
                    model.jumpToLatest()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            MentionSuggestionsView(
                document: $model.mentionDraft,
                autocomplete: model.mentionAutocomplete
            )
        }
        // Scoped to the pill's presence, never to the list's content: an ambient
        // animation here would animate row insertion in a bottom-anchored list.
        .animation(.smooth(duration: 0.2), value: model.heldBackCount > 0)
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
            symbol: ConversationTitleBar.symbol(for: identity.kind),
            title: identity.title,
            subtitle: subtitle(for: identity),
            action: { showsChannelDetails = true },
            actionHint: "Double tap to show conversation details"
        )
    }

    /// The header's second line: a channel's member count, or a direct peer's own quiet
    /// label.
    ///
    /// `2 members` under a person's name is a category error — a direct message *is* a
    /// two-member roster, so the number is a restatement of the fact that this is a DM.
    /// The peer's NIP-05 identifier (or "Agent") is what a reader does not already know,
    /// and it comes from the same ``EntityNames`` the sidebar and the details sheet read.
    /// The roster arrives asynchronously, so both branches may legitimately have nothing
    /// to say yet, and the pill then draws one line.
    private func subtitle(for conversation: ConversationIdentity) -> String? {
        if let peer = conversation.peer {
            return names.secondaryLabel(for: peer)
        }
        return ConversationTitleBar.memberCount(names.members(of: channelID).count)
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
    private func open(thread row: TimelineRow) {
        let root = row.rootID ?? row.id
        openedThread = ThreadRoute(root: root, channel: channelID)
    }

    /// A typer's name, through the injected directory — the same answer the sidebar,
    /// a message row, and a mention give. It replaces a scan of the loaded rows, which
    /// could only name someone who had already spoken in the page on screen.
    private func authorName(_ pubkey: String) -> String {
        names.name(for: pubkey)
    }
}

/// A pushed thread: its root id and the channel it lives in. No title — the thread
/// resolves its own heading through the shared directory, so a DM's thread cannot be
/// labelled with the group name the pushing view happened to be showing.
struct ThreadRoute: Hashable, Identifiable {
    let root: String
    let channel: String

    var id: String { root }
}
