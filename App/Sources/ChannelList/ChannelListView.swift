import BuzzKit
import Foundation
import SwiftUI

/// The sidebar (§8): Starred, Channels, Direct Messages, and Agents as expandable
/// sections of compact rows, live from the store, with your face and the connection state
/// in the toolbar. Tapping a conversation pushes its timeline; a long press stars it; the
/// Channels heading's `+` makes a new one; a pull refreshes the workspace.
///
/// # Why the app-wide environment lives here
///
/// This view is the only place *above* every pushed timeline, thread, and sheet, so it is
/// where the shared resolvers are injected: the `#channel` name→id map, the
/// name/avatar/conversation resolver, and the single clock behind relative timestamps. All
/// three are attached to the `NavigationStack` itself — above `navigationDestination` —
/// with the four `.task`s that drive them. A value injected *inside* the destination does
/// not reach the pushed view, so moving any down would cost every pushed surface its names.
///
/// It decides about the tab bar for the whole stack rather than leaving that to each
/// pushed view — see ``ChannelListTabBar``, which holds the measurements that put it here.
struct ChannelListView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: ChannelListModel
    @State private var presence: PresenceModel
    @State private var directory: EntityDirectoryModel
    @State private var ticker = RelativeTimeTicker()
    @State private var router: DirectMessageRouter
    /// Hiding a direct message. Owned here rather than injected, because this is the only
    /// surface that offers the action and the only one that can report its refusal — the
    /// row it was pressed on is gone by then.
    @State private var hider: HideDirectMessageModel
    /// The reader's starred conversations, on this device. Owned here because this view
    /// both groups by it and offers the action that changes it.
    @State private var starred = StarredConversations()
    /// How far this device has read into each thread. Owned here for the same reason the
    /// stars are: this view draws the number the marks subtract from, and it is the one
    /// place above both the Threads screen and the thread views that write them.
    @State private var threadReads = ThreadReadMarks()
    /// Every composer holding unsent text. Owned here for the reason the thread read
    /// marks are: this view draws the count and the pushed screen draws the list.
    @State private var draftsModel: DraftsModel
    /// The active community's picture, read from disk once per icon rather than once per
    /// `body`.
    ///
    /// Held here because the alternative is a filesystem read inside the heading's own
    /// `body`, and this `body` re-evaluates on everything the sidebar watches — an unread
    /// count arriving, presence moving, a row being read. `CommunityStorage.iconData(for:)`
    /// is a synchronous `Data(contentsOf:)` of up to half a megabyte
    /// (`RelayIcon.maximumInlineBytes`), so on that path it is a main-thread disk read
    /// several times a second for bytes that did not change. Refreshed by the `task` below,
    /// keyed on the community and the filename, so a new icon still lands.
    @State private var activeCommunityIcon: Data?
    @State private var showAccount = false
    /// Whether the new-channel sheet is up.
    @State private var showsCreateChannel = false
    /// The Threads screen, when it is pushed. A value rather than a `Bool` so it goes
    /// through `navigationDestination(item:)` like every other push in the app.
    @State private var showsThreads: ThreadsRoute?
    /// The Drafts screen, when it is pushed. A value rather than a `Bool`, like every
    /// other push here.
    @State private var showsDrafts: DraftsRoute?
    /// The thread the **Threads screen** has open, hoisted out of ``ThreadsView`` to here.
    ///
    /// State in the wrong place, but for ``ChannelListTabBar``: this stack has to know about
    /// every push that hides the tab bar, and a `@State` inside ``ThreadsView`` is a push it
    /// cannot see. Only the storage moved — that screen still declares the destination.
    @State private var openedThread: ThreadRoute?
    /// Whether the Later shortcut's "not built yet" notice is showing.
    @State private var showsLaterNotice = false
    /// The pushed conversations. Explicit, because every push here is programmatic —
    /// a row's button, a sheet that is already dismissing, a `#`-reference in a message.
    ///
    /// Typed, and not a `NavigationPath`: `NavigationPath` cannot be read back, so
    /// "is this conversation already on the stack?" is not a question it can answer, and
    /// the answer is what stops a DM opened from inside itself stacking on itself
    /// (see ``ConversationRoute/pushed(onto:)``).
    @State private var path: [ConversationRoute] = []
    /// Where the reader last was, for the leftward drag that takes them back to it.
    @State private var resume = ConversationResume()

    // Expansion persists across launches, one `UserDefaults` flag per section. The keys
    // come from ``SidebarSection/expansionStorageKey`` so the view and the tests that
    // pin those strings cannot drift apart.
    @AppStorage(SidebarSection.starred.expansionStorageKey)
    private var starredExpanded = SidebarSection.defaultIsExpanded
    @AppStorage(SidebarSection.channels.expansionStorageKey)
    private var channelsExpanded = SidebarSection.defaultIsExpanded
    @AppStorage(SidebarSection.directMessages.expansionStorageKey)
    private var directMessagesExpanded = SidebarSection.defaultIsExpanded
    @AppStorage(SidebarSection.agents.expansionStorageKey)
    private var agentsExpanded = SidebarSection.defaultIsExpanded

    private let store: BuzzEventStore
    private let engine: SyncEngine

    init(store: BuzzEventStore, engine: SyncEngine, drafts: ComposerDrafts? = nil, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        _draftsModel = State(initialValue: DraftsModel(store: store, drafts: drafts))
        _model = State(initialValue: ChannelListModel(store: store, selfPubkey: selfPubkey))
        _presence = State(initialValue: PresenceModel(store: engine.presenceStore))
        _directory = State(initialValue: EntityDirectoryModel(store: store))
        _router = State(initialValue: DirectMessageRouter(opener: engine))
        _hider = State(initialValue: HideDirectMessageModel(hider: engine))
    }

    var body: some View {
        // Derived once per pass and threaded down, so the resolver and the `#channel` map
        // are each built one time rather than once for the environment and again for the rows.
        let names = entityNames
        let channelNames = ChannelNameMap(channels: model.channels)
        // Resolved once per pass for the same reason the two above are: the highlight asks
        // about it on every row, and the answer is the same for all of them.
        let resumable = resume.resolved(among: model.visibleChannels)

        NavigationStack(path: $path) {
            sidebar(names: names, resumable: resumable?.channel.id)
                .overlay(alignment: .top) {
                    // Gated on the surface and not on having rows: an identity the relay
                    // confirmed is in *nothing* still needs to be told when a later refresh
                    // failed, and it is the reader who cannot tell "empty" from "offline"
                    // who most needs the Retry this carries.
                    if environment.channelDirectoryStatus == .cachedFallback,
                       model.surface == .conversations {
                        ChannelDirectoryFallbackBanner {
                            Task { await environment.retryConnectionAndDirectory() }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                }
                // The heading every other screen carries, naming the community this app is
                // signed in to (§ ``CommunityIdentity``). It opens the community list: this
                // is the one heading that names something you can be somewhere *else* than,
                // and the switcher is what that heading is for. Your account is still one
                // tap away at the trailing edge, where your own face is.
                .conversationTitle(
                    mark: activeCommunityMark,
                    // The active community's own label, which a rename changes and a switch
                    // replaces. It falls back to the relay-derived name for the frame before
                    // a community exists at all.
                    title: environment.communities.active?.name ?? CommunityIdentity.name(),
                    actionHint: "Double tap to switch community"
                ) {
                    environment.communitySheet = .switcher
                }
                // Drag left anywhere here to reopen the conversation just left — the
                // system's back swipe, mirrored. Declared inside the stack because the
                // transition it drives is that stack's own push.
                .sidebarForwardSwipe(reopening: resumable) { route in
                    path = route.pushed(onto: path)
                } close: {
                    path = []
                }
                .navigationDestination(for: ConversationRoute.self) { route in
                    ChannelTimelineView(
                        channel: route.channel,
                        store: store,
                        engine: engine,
                        drafts: environment.drafts,
                        uploader: { environment.mediaUploader },
                        selfPubkey: environment.selfPubkeyHex,
                        knownPeer: route.knownPeer,
                        focusingComposer: route.focusesComposer
                    )
                }
                .toolbar {
                    // One item, because two would push the heading towards the overflow
                    // menu ``ConversationTitleBar`` exists to stay out of — so the face
                    // carries the connection state that used to be a pill beside it.
                    ToolbarItem(placement: .topBarTrailing) { accountButton(names: names) }
                }
                .sheet(isPresented: $showAccount) {
                    AccountView(store: store, engine: engine, selfPubkey: environment.selfPubkeyHex)
                }
                // From the Channels heading's `+`. The push into the new channel arrives
                // once the sheet is gone — see ``View/createChannelSheet(isPresented:engine:open:)``.
                .createChannelSheet(isPresented: $showsCreateChannel, engine: engine) { channelID in
                    path = ConversationRoute(channel: conversationRow(for: channelID)).pushed(onto: path)
                }
                .navigationDestination(item: $showsDrafts) { _ in
                    DraftsView(model: draftsModel, open: openDraft)
                }
                // Declared here rather than inside the screen that pushes, because two
                // screens now open threads — the Threads screen and Drafts — and a stack
                // may hold only one destination per route type.
                .navigationDestination(item: $openedThread) { route in
                    ThreadView(
                        root: route.root,
                        channel: route.channel,
                        store: store,
                        engine: engine,
                        drafts: environment.drafts,
                        uploader: { environment.mediaUploader },
                        selfPubkey: environment.selfPubkeyHex,
                        landingOn: route.anchor,
                        focusingComposer: route.focusesComposer
                    )
                }
                .navigationDestination(item: $showsThreads) { _ in
                    ThreadsView(
                        store: store,
                        engine: engine,
                        selfPubkey: environment.selfPubkeyHex,
                        openedThread: $openedThread
                    )
                }
                .alert("Later isn't built yet", isPresented: $showsLaterNotice) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(
                        "Saving a message for later is coming. The shortcut is here so the "
                            + "rest of this screen can be built around it."
                    )
                }
        }
        // Declared here on the stack and by nothing below it — ``ChannelListTabBar`` holds
        // the measurements that put it here rather than on the pushed views.
        .toolbar(ChannelListTabBar.visibility(conversations: path, openedThread: openedThread), for: .tabBar)
        // The five app-wide values, injected once here for the reason in this view's own
        // documentation: a value injected *inside* the destination never reaches the pushed
        // view. So every surface names an identity identically (§4), ages its timestamps off
        // one tick (§7/§9), counts a thread against the same read marks this view subtracts,
        // and resolves a `#`-token through one map — rebuilt only when the channel set changes.
        // The last two are actions, and are here because their press happens in a pushed view
        // while the navigation it asks for belongs to this stack.
        .environment(\.channelNameMap, channelNames)
        .environment(\.entityNames, names)
        .environment(\.relativeTimeTicker, ticker)
        .environment(\.threadReadMarks, threadReads)
        .environment(\.directMessageRouter, router)
        // An already-open conversation is left alone by ``ConversationRoute/pushed(onto:)``, so
        // pressing a reference to the channel you are reading stacks nothing.
        .environment(\.openConversation, OpenConversationAction { channelID in
            let route = ConversationRoute(channel: conversationRow(for: channelID))
            path = route.pushed(onto: path)
        })
        // Watched rather than written at the two places that pop, so the system's own back
        // swipe — which runs no app code — fills the slot too. See ``ConversationResume``.
        .onChange(of: path) { previous, current in
            resume.observe(path: current, previously: previous)
        }
        // The router hands back an opened conversation once; this is the one place that turns
        // it into a push, and it clears the value so an unrelated body pass cannot re-push.
        .onChange(of: router.pendingConversation) { _, opened in
            guard let opened else { return }
            router.pendingConversation = nil
            let route = ConversationRoute(
                channel: conversationRow(for: opened.channelID),
                // The peer the relay named, carried only until the roster lands: it is what
                // lets a never-synced DM show the person's name, not the untitled placeholder.
                knownPeer: opened.peer
            )
            path = route.pushed(onto: path)
        }
        .alert(
            "Could not open the conversation",
            isPresented: Binding(
                get: { router.failure != nil },
                set: { if !$0 { router.failure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { router.failure = nil }
        } message: {
            Text(router.failure ?? "")
        }
        // On the stack rather than on the row: a successful hide removes the row that was
        // pressed, and a refused one has to be reported from something that outlives it.
        .alert(
            "Could not hide the conversation",
            isPresented: Binding(
                get: { hider.failure != nil },
                set: { if !$0 { hider.failure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { hider.failure = nil }
        } message: {
            Text(hider.failure ?? "")
        }
        .task { await model.run() }
        // The card's number only. The list itself is read by the pushed screen, so a table
        // written on every keystroke is not re-read behind a sidebar nobody is looking at.
        .task { await draftsModel.runCount() }
        .task { await presence.run() }
        .task { await directory.run() }
        .task { await ticker.run() }
        // Straight off the engine, deliberately not keyed on the mirrored status: a view
        // samples, and two verdicts in one main-actor turn are one body pass. See
        // ``ChannelListModel/trackDirectory(of:)``.
        .task { await model.trackDirectory(of: engine) }
        // Once per icon, not once per `body` — see ``activeCommunityIcon``. Keyed on the
        // community *and* its filename, so switching community and an operator replacing a
        // picture both land, and nothing else re-opens the file.
        //
        // The read itself stays on this actor. What was wrong was its *frequency*, not its
        // thread: one file open when the picture changes is ordinary, and hopping off the
        // actor to do it would buy a few milliseconds at the cost of a frame drawn without
        // the icon that was already there.
        .task(id: activeCommunityIconKey) {
            activeCommunityIcon = environment.communities.active
                .flatMap { environment.communityStorage.iconData(for: $0) }
        }
    }

    /// The fallback mark used before an active community graph exists. The running home
    /// heading uses ``activeCommunityMark`` so a cached picture or initials can replace this
    /// symbol without waiting for a relay response. RootView still needs this fallback while
    /// the identity gate is being composed.
    static let communitySymbol = "hexagon.fill"

    /// The one heading drawn in the accent: the workspace's own name is what the colour
    /// is *for*, where every other heading names a conversation inside it.
    static let communityMark = ConversationTitleBar.Mark.symbol(communitySymbol, accented: true)

    /// Carries the persisted community mark into the title-bar seam without asking the
    /// relay for anything. Kept pure so the cached-data contract can be pinned without
    /// launching a navigation stack.
    static func communityHeadingMark(
        name: String,
        iconData: Data?
    ) -> ConversationTitleBar.Mark {
        .community(name: name, iconData: iconData)
    }

    /// What VoiceOver is told about the marked row. Names the gesture rather than the
    /// colour, because the colour is not the point and cannot be perceived here anyway.
    static let resumeHint = "Last opened. Swipe left on this screen to reopen it."

    /// Why the sidebar is empty when the relay cannot be reached. It names the rule rather
    /// than apologising for it: Hive lists the conversations the relay confirms, so with no
    /// relay there is nothing it can honestly list.
    static let unreachableMessage =
        "Hive lists the conversations the relay confirms you’re in, so there’s nothing to show "
            + "until it answers. Your messages are still saved."
}

// MARK: - Content

private extension ChannelListView {
    /// The active community's mark, drawn from bytes already on this device.
    /// ``AppEnvironment/refreshCommunityIcon(for:)`` may still be checking the relay, but a
    /// network response must never be on the critical path for this heading: the old picture
    /// or the initials fallback is already an honest first frame.
    ///
    /// Reads ``activeCommunityIcon`` rather than the filesystem — see that property for why
    /// a `body` must not be the thing that opens the file.
    var activeCommunityMark: ConversationTitleBar.Mark {
        Self.communityHeadingMark(
            name: environment.communities.active?.name ?? CommunityIdentity.name(),
            iconData: activeCommunityIcon
        )
    }

    /// What ``activeCommunityIcon`` is refreshed against: which community, and which file
    /// under it. The filename is in the key because ``CommunityStorage/replacingIcon(_:for:)``
    /// reuses it when a community already had one, so an id alone would keep drawing the
    /// picture an operator has since changed.
    var activeCommunityIconKey: String {
        let community = environment.communities.active
        return "\(community?.id.uuidString ?? "-")|\(community?.iconFilename ?? "-")"
    }

    /// One flat list: the shortcut cards, then a heading row and its conversations for each
    /// grouping. `List` keeps the rows lazy and recycled; `SidebarRow.id` (the channel's
    /// group id) keeps their identity stable as unread counts stream in, so a re-read
    /// updates rows instead of rebuilding them.
    ///
    /// Flat, and not a `Section` per heading, because a plain list **pins** section headers
    /// — see ``SidebarSectionHeader``.
    ///
    /// The pull is the reader's escape hatch — ``SyncEngine/refresh()``. Here and on the
    /// Threads screen, and deliberately *not* on a conversation, where pulling down at the
    /// top of the history already means "load older messages".
    ///
    /// # Why there are three of these and not two
    ///
    /// A launch has a third state, and conflating it with "empty" is what put deleted
    /// channels on screen: until the relay has answered for this key, the app does not
    /// *know* what exists, and the honest thing to draw is neither a list nor "no
    /// conversations" but ``ChannelDirectoryPlaceholderList``.
    @ViewBuilder
    func sidebar(names: EntityNames, resumable: String?) -> some View {
        switch model.surface {
        case .connecting:
            ChannelDirectoryPlaceholderList(
                label: SidebarStatusPill.label(
                    for: environment.engineState,
                    hasConnectedBefore: environment.hasConnectedBefore
                )
            )
        case .unreachable:
            unreachableState
        case .conversations:
            conversations(names: names, resumable: resumable)
        }
    }

    @ViewBuilder
    func conversations(names: EntityNames, resumable: String?) -> some View {
        if model.visibleChannels.isEmpty {
            emptyState
        } else {
            List {
                shortcuts
                ForEach(sidebarContent(names: names).sections) { section in
                    SidebarSectionHeader(
                        section: section.section,
                        count: section.count,
                        isExpanded: expansion(for: section.section),
                        // Only Channels can be added to from here. A `+` on Starred would
                        // be a second way to spell a star, and neither a direct message
                        // (which starts from a person) nor an agent is made on the phone.
                        create: section.section == .channels ? { showsCreateChannel = true } : nil
                    )
                    .listRowInsets(Self.headerInsets)
                    .listRowSeparator(.hidden)
                    if expansion(for: section.section).wrappedValue {
                        if section.rows.isEmpty {
                            emptySectionRow(section.section)
                        } else {
                            rows(of: section, resumable: resumable)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await engine.refresh() }
        }
    }

    /// You, in the toolbar: the account sheet, with the engine's state as a dot.
    func accountButton(names: EntityNames) -> some View {
        let me = environment.selfPubkeyHex ?? ""
        return AccountAvatarButton(
            state: environment.engineState,
            picture: names.picture(for: me),
            seed: me,
            monogram: names.initials(for: me)
        ) {
            showAccount = true
        }
    }

    /// The Threads and Later cards, in one row above the conversations — one list row
    /// holding both, because they are a set of destinations rather than two rows.
    var shortcuts: some View {
        HomeShortcutCards(count: count(for:), press: press(_:))
            .listRowInsets(Self.cardsInsets)
            .listRowSeparator(.hidden)
    }

    func count(for shortcut: HomeShortcut) -> Int {
        switch shortcut {
        // The store's unread threads, less the ones this device has opened or replied in.
        case .threads: threadReads.unseenCount(among: model.unreadThreads)
        // Nothing is saved anywhere yet, so this is the truth rather than a placeholder.
        case .later: 0
        // Live from the store, de-duplicated so a keystroke does not move the card.
        case .drafts: draftsModel.count
        }
    }

    func press(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .threads: showsThreads = ThreadsRoute()
        case .later: showsLaterNotice = true
        case .drafts: showsDrafts = DraftsRoute()
        }
    }

    /// The conversations of one section.
    ///
    /// A `Button` and not a `NavigationLink`, which is the only way the trailing `>` goes: a
    /// link inside a `List` draws a disclosure indicator no modifier can decline. The push is
    /// the link's own — same route, same explicit path — and the press feedback it gave for
    /// free is ``PressFeedbackButtonStyle``, in its `row` emphasis: a full-width row that
    /// shrank would pull away from both screen edges and read as a card lifting off the list.
    /// The wash is the *button's* own press state and nothing else — UIKit cancels it when the
    /// forward swipe begins (``SidebarForwardSwipeView``), where a gesture reading press-down
    /// directly would leave every row it crossed dimmed behind the drag.
    func rows(of section: SidebarSectionContent, resumable: String?) -> some View {
        ForEach(section.rows) { row in
            // No peer hint from here: a conversation reached from the sidebar is one the
            // channel list already knows, so its roster is in hand.
            Button {
                let route = ConversationRoute(channel: row.channel)
                path = route.pushed(onto: path)
            } label: {
                ChannelRowView(row: row, presence: presence)
            }
            .buttonStyle(.hivePress(.row))
            .listRowInsets(Self.rowInsets)
            // No per-row rule: sections of ruled rows read as a form, not as one
            // navigation surface. The section headings do the separating.
            .listRowSeparator(.hidden)
            .listRowBackground(resumeMark(isResumable: row.id == resumable))
            // Spoken, because the highlight is the only thing that says so and a colour
            // says nothing to VoiceOver. A hint rather than part of the label: it describes
            // a second way to get here, not what this row is.
            .accessibilityHint(row.id == resumable ? Self.resumeHint : "")
            // Starring is a long press only. It had a leading swipe as well, and that swipe
            // is gone deliberately: a `List` row's swipe actions claim horizontal panning
            // for the row, which is the one axis this sidebar needs for navigating between
            // conversations. Losing it costs the fast path for someone who knew the flick
            // was there; keeping it would cost every reader the gesture that gets them back
            // to what they were reading.
            .contextMenu {
                starAction(row)
                // Only a one-to-one conversation. It was never reachable by swipe even when
                // this row had one: putting a conversation-removing action under a flick, on
                // a row that is about to vanish, is how one gets pressed by accident.
                if row.conversation.isDirect { hideAction(row) }
            }
        }
    }

    /// The mark on the row a leftward drag would reopen — where you just were.
    ///
    /// A wash of the accent behind the whole row rather than a bar, a dot or a badge: it has
    /// to be legible at a glance without competing with the two things this list already
    /// says with weight and colour — unread, and mentioned. A tinted row reads as *place*,
    /// which is what it means, and nothing else in the sidebar is trying to say that.
    ///
    /// Inset from the row's own bounds so it reads as a marked row rather than a full-width
    /// band, and rounded to match the glyph beside it.
    @ViewBuilder
    func resumeMark(isResumable: Bool) -> some View {
        if isResumable {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.hiveAccent.opacity(0.14))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        }
    }

    /// Star or unstar one conversation — the long press's only item, and the one place the
    /// wording of it is decided.
    func starAction(_ row: SidebarRow) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { starred.toggle(row.id) }
        } label: {
            Label(
                row.isStarred ? "Unstar" : "Star",
                systemImage: row.isStarred ? "star.slash" : "star"
            )
        }
        .tint(.yellow)
    }

    /// Takes one direct message off this sidebar — the relay's kind-41012 command, read
    /// back by every other client of this identity, Desktop included, from the same
    /// NIP-DV snapshot Hive reads.
    ///
    /// Not `role: .destructive`, and the wording is deliberate. Nothing is deleted and
    /// nobody is left: the messages stay, the other person keeps the conversation, and
    /// messaging them again brings it straight back — the relay's open command is what
    /// clears the hide. A red *Delete*-shaped item would promise a permanence this action
    /// does not have.
    func hideAction(_ row: SidebarRow) -> some View {
        Button {
            hider.hide(row.id)
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
        .disabled(hider.isHiding(row.id))
    }

    /// The relay answered, and the answer is that this key is in nothing.
    /// What a persistent heading shows instead of rows.
    ///
    /// A plain line of secondary text, not a `ContentUnavailableView`: that one centres
    /// itself in whatever space it is given and is built to own a screen, so inside a
    /// `List` row it opens a gap the size of the rest of the sidebar. This has to read
    /// as one quiet row under its heading.
    ///
    /// It is not a button. Nothing on this phone starts a direct message — a DM begins
    /// from a person, on their profile — so an empty DMs heading that offered a tap
    /// would be offering a dead end.
    func emptySectionRow(_ section: SidebarSection) -> some View {
        Text(section.emptyMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("sidebar-section-empty-\(section.rawValue)")
    }

    var emptyState: some View {
        ContentUnavailableView(
            "No conversations yet",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Channels and direct messages appear here as they sync from the relay.")
        )
    }

    /// The relay did not answer, and the grace period is over.
    ///
    /// It offers no list, and that is the point: the alternative is the saved one, which
    /// is a list of what *was* true and cannot be told apart from what is.
    var unreachableState: some View {
        ContentUnavailableView {
            Label("Can’t reach the relay", systemImage: "wifi.exclamationmark")
        } description: {
            Text(Self.unreachableMessage)
        } actions: {
            Button("Retry") {
                Task { await environment.retryConnectionAndDirectory() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("channel-directory-retry")
        }
        .accessibilityIdentifier("channel-directory-unreachable")
    }

    static let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
    static let headerInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    /// The cards sit slightly clear of the first heading's rule below them.
    static let cardsInsets = EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16)
}

// MARK: - Derivation

private extension ChannelListView {
    /// The resolver for this pass of the body: the live directory snapshot composed with
    /// the live channel list. Rebuilt only when one of those changes, and proportional to
    /// the identities that have *no* name, not to the roster.
    var entityNames: EntityNames {
        EntityNames(
            snapshot: directory.snapshot,
            channels: model.channels,
            selfPubkey: environment.selfPubkeyHex
        )
    }

    /// The row to push for a channel just opened or created.
    ///
    /// The live list first, so one conversation is one row value wherever it was reached
    /// from. A brand-new channel may not be in that list yet: the relay publishes a
    /// channel's metadata *after* it commits the channel, so the id is authoritative before
    /// the name is. Rather than block navigation on a read-back that can lose that race,
    /// this synthesises the minimum row the destination needs — everything a reader sees is
    /// resolved by ``EntityNames``. Two calls can legitimately answer with the same row;
    /// keeping one instance on the stack is ``ConversationRoute/pushed(onto:)``'s job.
    /// Opens the conversation a draft belongs to, with the composer already focused.
    ///
    /// Both destinations push *over* the Drafts screen rather than replacing it, so backing
    /// out returns to the list — a reader clearing several drafts one at a time should not
    /// have to walk back in from the sidebar each time.
    ///
    /// A thread carries its channel with it, so a thread draft pushes the thread alone: the
    /// channel underneath is not where the text is, and stacking it would put a screen the
    /// reader did not ask for between them and the way back.
    func openDraft(_ summary: ComposerDraftSummary) {
        switch DraftDestination.of(summary) {
        case let .thread(root, channel):
            openedThread = ThreadRoute(
                root: root,
                channel: channel,
                anchor: DraftDestination.threadLanding,
                focusesComposer: true
            )
        case let .conversation(channel):
            let route = ConversationRoute(
                channel: conversationRow(for: channel),
                focusesComposer: true
            )
            path = route.pushed(onto: path)
        }
    }

    func conversationRow(for channelID: String) -> ChannelListRow {
        if let existing = model.channels.first(where: { $0.id == channelID }) { return existing }
        return ChannelListRow(
            id: channelID,
            name: nil,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }

    /// The sections and rows for this pass, resolved once for the whole list.
    ///
    /// Deliberately does **not** read the presence roster: presence is consulted inside each
    /// row instead, so a heartbeat invalidates the small views that draw a dot rather than
    /// re-deriving every section (§9).
    func sidebarContent(names: EntityNames) -> SidebarContent {
        SidebarContent.build(channels: model.visibleChannels, names: names, starred: starred.ids)
    }

    /// The persisted expansion flag for a section.
    func expansion(for section: SidebarSection) -> Binding<Bool> {
        switch section {
        case .starred: $starredExpanded
        case .channels: $channelsExpanded
        case .directMessages: $directMessagesExpanded
        case .agents: $agentsExpanded
        }
    }
}
