import BuzzKit
import SwiftUI

/// A thread: its opener, a divider, then every reply oldest-first, each with its
/// reaction chips and actions sheet, and a reply composer floating below. Reads are
/// live from the store; opening fetches the thread's replies once so it fills even
/// before live fan-out catches up.
///
/// The same ``ConversationScaffold`` as the channel timeline, minus pagination — a
/// thread is loaded whole — so the keyboard, the safe area, and the floating bar
/// behave identically without a second copy of that arithmetic.
struct ThreadView: View {
    @Environment(\.entityNames) private var names
    /// Pops back to the conversation this thread hangs off — the heading's own action, and
    /// the same pop the back button and the edge swipe perform, so there is one way out
    /// rather than three that could diverge.
    @Environment(\.dismiss) private var dismiss
    @State private var model: ThreadModel
    /// The same workspace roster the channel timeline reads, so a reply's presence dot
    /// and the profile sheet this view presents agree with the row that pushed it.
    @State private var presence: PresenceModel
    /// Who is typing *in this thread*. A second model rather than a shared one: the
    /// channel's and the thread's are different audiences — see ``ChannelTypingModel``.
    @State private var typing: ChannelTypingModel
    @State private var access: ChannelAccessModel
    /// Whose profile is open, if anyone's — set by a tap on a reply's avatar or name.
    @State private var profilePeer: ProfilePeer?
    /// The reply whose actions sheet is open, if any — set by a long press on a row.
    @State private var messageActions: MessageActionTarget?
    /// Whether the participants sheet is open — the `person.3.fill` in the bar.
    @State private var showsPeople = false
    /// Whether a join started from the bar is on the wire — see the channel's own.
    @State private var isJoining = false
    /// This device's per-thread read marks. Absent on a surface reached without them (the
    /// conversation fixture), where nothing is recorded.
    @Environment(\.threadReadMarks) private var threadReads
    /// Optional for ``ChannelTimelineView``'s reason: the non-optional form traps before any
    /// `body` runs when this surface is mounted outside the app graph, which is what the
    /// fixtures do.
    @Environment(AppEnvironment.self) private var appEnvironment: AppEnvironment?
    private let channelID: String
    /// Kept so the participants sheet can start its own presence stream. The `presence`
    /// model above is this view's; a sheet is a separate lifetime and reads it from the
    /// same store rather than borrowing a model whose `.task` belongs to this screen.
    private let presenceStore: PresenceStore
    /// Joins the channel this thread hangs off, for the bar a non-member sees.
    ///
    /// Optional and defaulted, because three of this view's four call sites reach it
    /// through the production initialiser and hand a whole `SyncEngine`; only the channel
    /// timeline names its collaborators one by one, and only a fixture has none. Absent, a
    /// non-member still gets the bar and its explanation — the button is simply not
    /// offered, which is the honest answer on a surface with nothing to join through.
    private let joiner: (any ChannelJoining)?
    /// Reports this exact thread as a recent recovery destination. Optional so the real
    /// conversation surface remains mountable with protocol fakes in UI tests.
    private let lifecycleEngine: SyncEngine?

    /// The mark on a thread's heading. `text.append` rather than a bubble or an arrow: it is
    /// the symbol for adding a line to something already written, which is what a thread is.
    /// Named here rather than at the call site so the test that it is a symbol the system
    /// actually has can reach it — a missing name renders as nothing at all, silently.
    static let threadSymbol = "text.append"

    /// Where this thread rests when it opens. A thread reached from a message in its own
    /// channel opens at the newest reply — the reader has the opener in front of them
    /// already. One reached from the Threads screen's row opens at the opener instead,
    /// because that row's tap is the question "what is this about".
    private let landing: ThreadLanding

    /// Whether the reply composer takes the keyboard once this thread has settled on screen.
    ///
    /// Set by the actions sheet's "Reply in thread" and by nothing else — see
    /// ``SwiftUI/View/focusesComposerOnArrival(_:focus:)`` for why it waits rather than
    /// firing on appearance.
    private let focusesComposer: Bool

    /// The production initialiser: the engine is all three of the collaborators below.
    init(
        root: String,
        channel: String,
        store: BuzzEventStore,
        engine: SyncEngine,
        drafts: ComposerDrafts? = nil,
        uploader: @escaping MediaUploaderProvider,
        selfPubkey: String?,
        landingOn landing: ThreadLanding = .latestReply,
        focusingComposer focusesComposer: Bool = false
    ) {
        self.init(
            root: root,
            channel: channel,
            store: store,
            sender: engine,
            opener: engine,
            presence: engine.presenceStore,
            typing: engine,
            drafts: drafts,
            uploader: uploader,
            selfPubkey: selfPubkey,
            joiner: engine,
            lifecycleEngine: engine,
            landingOn: landing,
            focusingComposer: focusesComposer
        )
    }

    /// The same view, with its collaborators named rather than taken from a `SyncEngine`.
    ///
    /// ``ThreadModel`` was always written against `MessageSending` and `ThreadOpening`; only
    /// this view's initialiser reached for the concrete engine, and a `SyncEngine` cannot be
    /// built without a relay socket. That made the scroll surface unreachable from a UI test,
    /// so the thirteen shapes that found the `#49`/`#50`/`#52` defects lived outside the repo
    /// and gated nothing — they rendered a *copy* of this screen, which is free to drift from
    /// it.
    ///
    /// This initialiser exists so a test drives **this** view. It adds no behaviour: the
    /// production path above delegates straight to it.
    init(
        root: String,
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        opener: any ThreadOpening,
        presence: PresenceStore,
        typing: any EphemeralPublishing = NoopEphemeralPublisher(),
        drafts: ComposerDrafts? = nil,
        uploader: @escaping MediaUploaderProvider,
        selfPubkey: String?,
        joiner: (any ChannelJoining)? = nil,
        lifecycleEngine: SyncEngine? = nil,
        landingOn landing: ThreadLanding = .latestReply,
        focusingComposer focusesComposer: Bool = false
    ) {
        channelID = channel
        presenceStore = presence
        self.joiner = joiner
        self.lifecycleEngine = lifecycleEngine
        self.landing = landing
        self.focusesComposer = focusesComposer
        _model = State(initialValue: ThreadModel(
            root: root,
            channel: channel,
            store: store,
            sender: sender,
            opener: opener,
            typing: typing,
            drafts: drafts,
            uploader: uploader,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presence))
        _typing = State(initialValue: ChannelTypingModel(
            channel: channel,
            thread: root,
            store: presence,
            selfPubkey: selfPubkey
        ))
        _access = State(initialValue: ChannelAccessModel(
            channelID: channel,
            identity: selfPubkey,
            store: store
        ))
    }

    var body: some View {
        // The thread is read here rather than in `init` (see `primeIfNeeded()`): a `body`
        // runs before layout, so the bottom anchor still resolves against real content,
        // while the view structs SwiftUI initialises and discards on every commit cost an
        // allocation instead of three blocking store reads on the main actor.
        model.primeIfNeeded()

        return ConversationScaffold(
            // Hand-written rather than `$model.isAtBottom`, which would write the
            // model reference back into `State` on every scroll threshold crossing.
            isAtBottom: Binding(get: { model.isAtBottom }, set: { model.isAtBottom = $0 }),
            jumpToken: model.jumpToken,
            jumpTarget: model.jumpTarget,
            contentRevision: model.contentRevision,
            rowRevision: model.rowRevision,
            newestID: model.items.newestMessageID,
            composerRevision: model.attachments.barRevision,
            onLeavingScreen: releaseComposer
        ) {
            list
        } bar: {
            bar
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        .focusesComposerOnArrival(focusesComposer) { model.mentionAutocomplete.isComposerFocused = true }
        // The tab bar is hidden for a thread, for the same reason it is hidden for a
        // channel: a thread is a reading surface with a composer, and the bar would be a
        // second bottom inset under it. Declared by the view that owns the stack rather than
        // here — see ``ChannelListView/hidesTabBar``, which also explains why this view
        // keeping a `.hidden` of its own would not have been a harmless belt-and-braces: a
        // stack-level `.visible` beats it, so the two have to agree, so only one of them may
        // speak.
        .conversationTitle(
            mark: .symbol(Self.threadSymbol),
            title: "Thread",
            subtitle: .text(context),
            actionHint: "Double tap to return to the conversation",
            action: { dismiss() },
            // A thread has no roster — you are not a *member* of one — so the only honest
            // answer to "who is in here" is whoever has spoken, which is what the rows say.
            // No `⋮` beside it: there is nothing about a thread to manage, and the channel
            // it hangs off has its own.
            peopleAction: { showsPeople = true }
        )
        .sheet(isPresented: $showsPeople) {
            ConversationPeopleSheet(
                threadParticipants: participants,
                presenceStore: presenceStore
            )
        }
        .profileSheet(peer: $profilePeer, presence: presence)
        // The channel's sheet, minus "Reply in thread": this *is* the thread.
        .messageActionsSheet(
            target: $messageActions,
            actions: model,
            isReadOnly: !access.allowsInteraction,
            onRemind: { row, due in
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
        // After the first render, so the scaffold's `onChange(of: jumpToken)` is installed
        // and the bump is a transition it sees — see ``ThreadModel/landOnOpener()``.
        .task { if landing == .opener { model.landOnOpener() } }
        .task { await model.run() }
        .task { await lifecycleEngine?.setActiveThread(channel: channelID, root: model.root) }
        .task { await presence.run() }
        // Here rather than inside ``TypingIndicatorView``, which is absent from the view
        // tree until somebody is typing and so could never start its own model — see the
        // note on that type. The surface that owns the model runs it, as above.
        .task { await typing.run() }
        .task { await access.run() }
        // Mark-on-view, the same discipline the channel's read state follows — and the
        // *rendered* newest row for the same reason: a reply held behind a frozen tail has
        // not been seen, so it must still count as new. Being here rather than in the model
        // is deliberate: this marker never leaves the device, so it is view state, not
        // something the thread publishes. Replying is covered without a second path — a sent
        // reply is a new newest row.
        .onChange(of: model.rows.last?.createdAt, initial: true) { _, newest in
            guard let newest else { return }
            threadReads?.mark(model.root, seenUpTo: newest)
        }
    }

    // MARK: - List

    private var list: some View {
        // The channel's rhythm, from the same constant, so a message does not change
        // size or spacing when a reader follows it into its thread.
        // Newest first and each row flipped back, as the channel does — the scaffold is shared,
        // so the inversion is not optional here. See ``View/conversationInverted()``.
        LazyVStack(spacing: MessageRowMetrics.withinGroup) {
            // The same grouped items the channel renders, so a thread that spans days
            // separates them the same way and stacks one person's consecutive replies the
            // same way; the model suppresses the separator that would otherwise sit above
            // the thread's own opener.
            ForEach(model.items.reversed()) { item in
                itemView(item)
                    .padding(.bottom, item.continuesGroup ? 0 : MessageRowMetrics.aboveNewGroup)
                    .conversationInverted()
            }
        }
        .padding(.vertical, 8)
        .dismissesSuggestionsOnScroll(model.mentionAutocomplete)
    }

    @ViewBuilder
    private func itemView(_ item: ConversationItem) -> some View {
        switch item {
        case let .day(marker):
            DaySeparatorView(date: marker.date)
        case let .message(row, continuesGroup):
            messageRow(row, continuesGroup: continuesGroup)
        case let .notice(marker):
            // A thread's rows are all kind-9 replies, so this is unreachable today.
            // Rendered rather than skipped so that a notice which ever does reach a
            // thread appears instead of silently vanishing.
            SystemNoticeRowView(notice: marker.notice, alsoJoined: marker.alsoJoined, date: marker.date)
        }
    }

    private func messageRow(_ row: TimelineRow, continuesGroup: Bool) -> some View {
        // One view per element: the lazy stack's per-element subview count stays
        // constant as replies stream in, so the bottom anchor never fights a row that
        // is sometimes one child and sometimes two.
        VStack(spacing: 0) {
            TimelineRowView(
                row: row,
                showsAuthorHeader: !continuesGroup,
                isAuthorOnline: presence.isOnline(row.pubkey),
                reactions: model.reactions(for: row.id),
                mentions: model.mentions(for: row.id),
                selfPubkey: model.selfPubkey,
                allowsInteraction: access.allowsInteraction,
                onRetry: { model.retry($0) },
                onReact: { model.react($0, on: row.id) },
                onToggleReaction: { model.toggleReaction($0, on: row.id) },
                // No `onOpenThread`: a reply inside a thread has nowhere further to go,
                // which is also why no row here draws a reply preview.
                onLongPress: { messageActions = messageActionTarget(for: row) },
                onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) },
                conversation: conversation
            )
            // The shared constant rather than a bare `.padding(.horizontal)`, so a reply
            // starts on the same line as the header pill and the day separators above it.
            .padding(.horizontal, MessageRowMetrics.rowLeading)

            // Set the opener apart from its replies, and furnish that rule — see
            // ``ThreadOpenerDivider``. The row in hand *is* the opener, by this branch.
            if row.id == model.root {
                ThreadOpenerDivider(
                    replyCount: model.replyCount,
                    onOpenActions: { messageActions = messageActionTarget(for: row) }
                )
            }
        }
    }

    private var accessory: some View {
        // A local `Bindable` rather than `$model`: a binding projected through `State`
        // of an observable class writes the reference back into `State` on every set,
        // invalidating this whole view where only the composer needed to hear about it.
        @Bindable var model = model
        return VStack(spacing: 8) {
            ChannelAccessBanner(state: access.state)
            // The channel's control, reading the thread's own jump state — see the
            // note on ``ChannelTimelineView``'s accessory for why the count is read
            // inside that view and not here.
            ConversationJumpControls(
                state: model.jump,
                onJumpToNew: { model.jumpToNewMessages() }
            )
            MentionSuggestionsView(
                document: $model.mentionDraft,
                autocomplete: model.mentionAutocomplete
            )
            // Scoped to this thread's root, so it says who is writing *here* — and says
            // nothing about the channel's other traffic, which a reader inside a thread
            // cannot see and did not ask about. The channel's own strip is the wide one:
            // it covers its threads, because from there they are not distinguishable.
            TypingIndicatorView(model: typing, nameFor: names.name(for:))
            // The same strip the channel carries, for the same reason: a thread read
            // over a dead socket looks exactly like a thread nobody has replied to.
            ConnectionStatusIndicatorView()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded, model.rows.isEmpty {
            ContentUnavailableView(
                "Thread unavailable",
                systemImage: "text.bubble",
                description: Text("This thread couldn't be loaded.")
            )
        }
    }

    /// The conversation this thread hangs off, resolved through the shared directory
    /// rather than carried down from the pushing view — so a thread inside a DM is
    /// labelled with the person, not with the group the relay happens to have named.
    private var conversation: ConversationIdentity {
        names.conversation(for: channelID)
    }

    /// The line under "Thread": `#channel` for a channel, and a plain name for a direct
    /// message, where a `#` would be a category error.
    ///
    /// The heading names the way out and takes it: the second line already says which
    /// conversation this thread hangs off, so tapping it goes there. That it duplicates the
    /// back button beside it is the point — it is the larger target, and it is the one a
    /// reader's eye is already on.
    private var context: String {
        conversation.isDirect ? conversation.title : "#\(conversation.title)"
    }

    /// Who has spoken in this thread. Derived from the rows already on screen rather than
    /// queried, so the sheet cannot disagree with what the reader can scroll through.
    private var participants: [ConversationPerson] {
        ConversationPerson.threadParticipants(in: model.rows, root: model.root)
    }

    /// The scaffold's "this surface is leaving the screen" report. A reply composer's
    /// keyboard must not outlive the thread it belongs to — nor be restored under the
    /// channel once this view is gone, which is what UIKit does if the responder is still
    /// held when the window detaches.
    private func releaseComposer() {
        model.mentionAutocomplete.dismissComposer()
    }

    private func messageActionTarget(for row: TimelineRow) -> MessageActionTarget {
        .init(row: row, isOwn: model.isOwn(row), channelID: channelID, threadRootID: model.root)
    }
}

private extension ThreadView {
    /// What stands at the bottom of the thread — the channel's own rule, applied to the
    /// thread's own composer.
    ///
    /// See ``ChannelTimelineView/bar`` for why `.readOnly` keeps today's composer, and why
    /// this replaces rather than stacks.
    @ViewBuilder
    var bar: some View {
        switch access.participation {
        case .allowed, .readOnly:
            ThreadComposerView(model: model)
                .disabled(!access.isWritable)
        case .joinRequired:
            ChannelJoinBar(
                name: conversation.title,
                isJoining: isJoining,
                join: joiner.map { joiner in { joinThisChannel(through: joiner) } }
            )
        }
    }

    /// Joins the channel this thread hangs off, without leaving the thread.
    ///
    /// The channel's own, and for the same reasons — nothing is assigned on success,
    /// because ``ChannelAccessModel`` is already watching the commit this awaits. A join
    /// taken here returns the composer on both surfaces: the channel underneath is reading
    /// the same store on the same signal.
    func joinThisChannel(through joiner: any ChannelJoining) {
        guard !isJoining else { return }
        isJoining = true
        Task {
            defer { isJoining = false }
            try? await joiner.joinChannel(channelID) { _ in }
        }
    }
}

/// The reply composer: a Liquid Glass capsule field and a prominent send button, the
/// same treatment as the channel composer — and, since Part 14, the same typing publish,
/// scoped to this thread rather than to the channel around it.
private struct ThreadComposerView: View {
    @Bindable var model: ThreadModel

    var body: some View {
        MessageComposerView(
            document: $model.mentionDraft,
            autocomplete: model.mentionAutocomplete,
            attachments: model.attachments,
            placeholder: "Reply",
            sendAccessibilityLabel: "Send reply",
            onTextChange: model.handleTyping,
            onSend: model.sendReply
        )
        .alert(
            "Reply not sent",
            isPresented: Binding(
                get: { model.sendError != nil },
                set: { if !$0 { model.sendError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.sendError = nil }
        } message: {
            Text(model.sendError ?? "")
        }
    }
}
