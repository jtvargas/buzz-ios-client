import BuzzKit
import Foundation
import SwiftUI

/// The sidebar (§8): Starred, Channels, Direct Messages, and Agents as expandable
/// sections of compact rows, live from the store, with your face and the connection state
/// in the toolbar. Tapping a conversation pushes its timeline; a long press stars it; the
/// Channels heading's `+` opens the channel browser, where joining and creating live; a
/// pull refreshes the workspace.
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
    /// Whether the channel browser is up — the Channels heading's `+`.
    @State private var showsBrowseChannels = false
    /// Whether the new-channel sheet is up. No trigger sets it from this screen any
    /// more — creating moved inside the browser — but the seam stays attached: it is
    /// the documented adoption point for the sheet, and a fixture can still drive it.
    @State private var showsCreateChannel = false
    /// Whether the new-direct-message sheet is up.
    @State private var showsNewDirectMessage = false
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
    /// The pushed Later screen. A route rather than a `Bool` so it sits alongside the
    /// other programmatic pushes this stack owns.
    @State private var showsLater: LaterRoute?
    /// Drives the Later screen and keeps the scheduled alerts in step. Built here rather
    /// than inside the screen so the shortcut card's count is live whether or not anyone
    /// has opened it.
    @State private var laterModel: LaterModel?
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
    /// How far the communities panel is out — 0 closed, 1 over the sidebar. Held here rather
    /// than inside the panel because three things move it: the rightward drag, the heading's
    /// tap, and the panel's own strip.
    @State private var workspacePanel = WorkspacePanelState()

    @Binding private var notificationRoute: InAppNotificationRoute?
    @Binding private var visibleNotificationLocation: InAppNotificationLocation?

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

    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        drafts: ComposerDrafts? = nil,
        selfPubkey: String?,
        notificationRoute: Binding<InAppNotificationRoute?> = .constant(nil),
        visibleNotificationLocation: Binding<InAppNotificationLocation?> = .constant(nil)
    ) {
        self.store = store
        self.engine = engine
        _notificationRoute = notificationRoute
        _visibleNotificationLocation = visibleNotificationLocation
        _draftsModel = State(initialValue: DraftsModel(store: store, drafts: drafts))
        _model = State(initialValue: ChannelListModel(store: store, selfPubkey: selfPubkey))
        _presence = State(initialValue: PresenceModel(store: engine.presenceStore))
        _directory = State(initialValue: EntityDirectoryModel(store: store, selfPubkey: selfPubkey))
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
                // The onboarding ground, by the owner's call, in place of the system's own.
                // A plain `List` in dark mode sits on `systemBackground`, which is pure
                // black; ``ShapeStyle/hiveNight`` is the colour the honeycomb composites
                // over, so the sidebar and the first screen anyone sees are one dark rather
                // than two that are nearly the same.
                //
                // On the container rather than on the `List`, because the sidebar has four
                // surfaces — the placeholder bars, the two `ContentUnavailableView`s and the
                // list itself — and a ground applied to only the last of them would flash
                // black for as long as the relay takes to answer.
                .hiveScreenGround()
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
                    actionHint: "Double tap to switch community",
                    // Leaves at the speed of the finger. The panel is what replaces this
                    // heading, so the heading has to go as the panel arrives rather than
                    // the moment the drag starts.
                    opacity: 1 - workspacePanel.progress
                ) {
                    // The same panel the rightward drag brings, arriving under its own
                    // animation rather than a finger's — a heading that opened something
                    // *else* would make the two ways in two different features.
                    workspacePanel.setOpen(true)
                }
                // The communities, over the sidebar. Both layers are declared here, in this
                // order, so the panel is above the darkness it casts.
                .overlay { WorkspacePanelScrim(state: workspacePanel) }
                .overlay(alignment: .leading) { workspacePanelOverlay }
                .workspacePanelDrag(workspacePanel, isAvailable: path.isEmpty && openedThread == nil)
                // Drag left anywhere here to reopen the conversation just left — the
                // system's back swipe, mirrored. Declared inside the stack because the
                // transition it drives is that stack's own push.
                //
                // Refused outright while the panel is out: leftward is how the panel is
                // pushed back, and two recognisers that both claim simultaneity with pans
                // would otherwise both run — closing the panel *and* opening a conversation
                // behind it on the same drag.
                .sidebarForwardSwipe(reopening: workspacePanel.isOpen ? nil : resumable) { route in
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
                        knownPeers: route.knownPeers,
                        focusingComposer: route.focusesComposer
                    )
                }
                .toolbar {
                    // One item, because two would push the heading towards the overflow
                    // menu ``ConversationTitleBar`` exists to stay out of — so the face
                    // carries the connection state that used to be a pill beside it.
                    ToolbarItem(placement: .topBarTrailing) {
                        accountButton(names: names)
                            // Leaves with the heading opposite it, at the same rate and for
                            // the same reason: the bar belongs to the sidebar, and the panel
                            // is covering the sidebar. Faded rather than removed so the bar's
                            // layout does not shift under the fade.
                            .opacity(1 - workspacePanel.progress)
                            .allowsHitTesting(workspacePanel.progress < 0.5)
                            .accessibilityHidden(workspacePanel.progress >= 0.5)
                    }
                    // The account button draws its own hexagonal glass, so the toolbar's
                    // automatic circular background must stay hidden.
                    .sharedBackgroundVisibility(.hidden)
                }
                .sheet(isPresented: $showAccount) {
                    AccountView(store: store, engine: engine, selfPubkey: environment.selfPubkeyHex)
                }
                // From the Channels heading's `+`: browse, join, or create. The push into
                // the chosen channel arrives once the sheet is gone — see
                // ``View/browseChannelsSheet(isPresented:store:identity:engine:open:)``.
                .browseChannelsSheet(
                    isPresented: $showsBrowseChannels,
                    store: store,
                    identity: environment.selfPubkeyHex,
                    engine: engine
                ) { channelID, browsed in
                    path = ConversationRoute(
                        channel: conversationRow(for: channelID, fallback: browsed)
                    ).pushed(onto: path)
                }
                // The new-channel sheet's standing seam — the browser presents its own;
                // see ``showsCreateChannel`` for why this stays.
                .createChannelSheet(isPresented: $showsCreateChannel, engine: engine) { channelID in
                    path = ConversationRoute(channel: conversationRow(for: channelID)).pushed(onto: path)
                }
                // From the Direct Messages heading's `+`. The people are mapped in the
                // closure rather than passed as a value, so the whole directory is walked
                // when the sheet opens rather than on every pass of this body — which
                // re-evaluates on an arriving message, a heartbeat, a row being read.
                //
                // The open is asked for once the sheet is gone, and the push it produces
                // arrives through the same `pendingConversation` change every other DM does.
                .newDirectMessageSheet(
                    isPresented: $showsNewDirectMessage,
                    people: { directMessagePeople(names: names) },
                    maxSelection: SyncEngine.maxDirectMessagePeers,
                    open: { router.open(with: $0) }
                )
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
                .navigationDestination(item: $showsLater) { _ in laterDestination }
        }
        // Declared here on the stack and by nothing below it — ``ChannelListTabBar`` holds
        // the measurements that put it here rather than on the pushed views.
        //
        // Hidden outright while the communities panel is out, because that panel is
        // full-height: a tab bar drawn over its bottom edge would put Home and Activity on
        // top of **Scan QR from Desktop**, and the reference the owner gave has nothing there.
        .toolbar(
            workspacePanel.isOpen
                ? .hidden
                : ChannelListTabBar.visibility(conversations: path, openedThread: openedThread),
            for: .tabBar
        )
        // And the navigation bar's own material with it, though the bar itself stays.
        //
        // The bar draws *over* the panel — the panel is content inside this stack — so its
        // blur was landing on the panel's own heading and haloing it. Hiding the background
        // rather than the bar is deliberate: hiding the bar would reclaim its height and
        // shift the sidebar underneath, which is visible in the strip beside the panel.
        .toolbarBackgroundVisibility(workspacePanel.isOpen ? .hidden : .automatic, for: .navigationBar)
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
        .onChange(of: notificationLocation, initial: true) { _, location in
            visibleNotificationLocation = location
        }
        .onChange(of: notificationRoute, initial: true) { _, route in
            guard let route else { return }
            notificationRoute = nil
            openNotification(route)
        }
        .onDisappear { visibleNotificationLocation = nil }
        // A tapped reminder alert is not read here any more. It arrives as a destination on
        // ``AppNavigator``, through the very same observer — see ``ReminderAlerts``. It used
        // to pop to the sidebar and stop there, which the owner asked for in #121 and then
        // asked to change back: the tap is a request for the Later screen after all.
        //
        // A screen asked for from outside the view tree — Siri, Spotlight, the Shortcuts app,
        // a reminder alert. The request names a destination and knows nothing else; this is
        // the one place that turns it into a push, and it clears the request as it acts so an
        // unrelated body pass cannot re-push. ``RootView`` has already selected the tab.
        //
        // `initial: true` because a request that *launches* the app is written while this
        // view does not exist yet, and there is no second signal. Without it, "Open Threads
        // in Hive" from a cold start opens the app onto the sidebar and stops — and so does
        // a reminder alert tapped from the lock screen.
        .onChange(of: environment.navigator.pending, initial: true) { _, target in
            guard let target else { return }
            environment.navigator.consume()
            open(target)
        }
        // The router hands back an opened conversation once; this is the one place that turns
        // it into a push, and it clears the value so an unrelated body pass cannot re-push.
        .onChange(of: router.pendingConversation) { _, opened in
            guard let opened else { return }
            router.pendingConversation = nil
            let route = ConversationRoute(
                channel: conversationRow(for: opened.channelID),
                // The people the tap named, carried only until the roster lands: it is what
                // lets a never-synced DM show their names, not the untitled placeholder.
                knownPeers: opened.peers
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
        // Built and observed here rather than inside ``LaterView``, so the shortcut card's
        // count is live before anyone opens the screen — and so the alerts stay reconciled
        // with what is pending even when the screen has never been on.
        .task {
            guard laterModel == nil else { return }
            let model = LaterModel(
                store: store,
                engine: engine,
                // Read through the environment's settings rather than captured, so the
                // reconciler that runs on every projection change asks the switch its current
                // answer — this model outlives any number of visits to the settings screen.
                scheduler: ReminderScheduler(
                    notificationsEnabled: { environment.settings.notificationsEnabled }
                ),
                authorName: { names.name(for: $0) }
            )
            laterModel = model
            await model.run()
        }
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
                    sectionCell(section, resumable: resumable)
                }
            }
            .listStyle(.plain)
            .refreshable { await engine.refresh() }
        }
    }

    /// What a section's `+` does, or `nil` for a section that nothing is added to from here.
    /// Channels opens the browser rather than the create form: search, join, and create
    /// live behind one entry point, as they do on Desktop.
    func create(for section: SidebarSection) -> (() -> Void)? {
        switch section {
        case .channels: { showsBrowseChannels = true }
        case .directMessages: { showsNewDirectMessage = true }
        case .starred, .agents: nil
        }
    }

    /// The people the new-direct-message sheet offers: every identity the directory knows,
    /// resolved to plain values here and not inside the sheet.
    ///
    /// This is the one place that knows how an identity is *named*, which is where that
    /// knowledge already lives — and keeping it here is what leaves the sheet a view over an
    /// array, testable and previewable without a store or an engine.
    ///
    /// You are left out. BuzzKit drops your own key from an open command anyway (the relay
    /// merges the author in), so a row for yourself would be one that silently did nothing.
    func directMessagePeople(names: EntityNames) -> [DirectMessagePerson] {
        let me = environment.selfPubkeyHex?.lowercased()
        return names.identities.compactMap { pubkey in
            guard pubkey != me else { return nil }
            return DirectMessagePerson(
                pubkey: pubkey,
                name: names.name(for: pubkey),
                secondary: names.secondaryLabel(for: pubkey),
                picture: names.picture(for: pubkey),
                initials: names.initials(for: pubkey),
                isAgent: names.isAgent(pubkey),
                isNamed: names.humanName(for: pubkey) != nil
            )
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
        HomeShortcutCards(count: count(for:), isCalling: isCalling(_:), press: press(_:))
            .listRowInsets(Self.cardsInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// The communities panel, sized against the real screen.
    ///
    /// A `GeometryReader` rather than a constant, because the drag's arithmetic and what is
    /// drawn have to agree on one number: 85% of a guess is a panel that arrives before or
    /// after the finger does, and the mismatch is exactly the thing a hand notices.
    ///
    /// Inert until it is out. At rest the panel sits off the leading edge with its strip
    /// lying over the left of the sidebar, and a strip that could be tapped there would be an
    /// invisible control over the channel rows.
    var workspacePanelOverlay: some View {
        GeometryReader { proxy in
            WorkspacePanel(
                state: workspacePanel,
                width: WorkspacePanelGeometry.width(inScreenOf: proxy.size.width)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(workspacePanel.isOpen)
    }

    /// The Later screen. Lifted out of the stack's builder because that builder is already
    /// at the type-checker's limit — inlining this one pushed it over.
    ///
    /// **The `else` is load-bearing — it is not dead code.** ``laterModel`` is built by this
    /// view's own `.task`, and ``open(_:)`` can push this screen before that task has run: an
    /// intent's request is read in an `.onChange(initial: true)` during the first update
    /// transaction, and a `.task` body is enqueued behind it. A bare `if let` evaluates to
    /// `EmptyView`, so a cold-launch "Open Later in Hive" pushes a blank screen whose only
    /// control is Back. No finger can reach here that early — ``press(_:)`` needs a sidebar
    /// already on screen — which is why the gap opened only once something outside the view
    /// tree could ask for this screen. Chrome but no spinner: the model lands a frame later.
    @ViewBuilder
    var laterDestination: some View {
        if let laterModel {
            LaterView(
                model: laterModel,
                channelName: { conversationRow(for: $0).name ?? "" },
                openTarget: { target in
                    showsLater = nil
                    path = ConversationRoute(
                        channel: conversationRow(for: target.channelID)
                    ).pushed(onto: path)
                }
            )
        } else {
            Color.clear
                .hiveScreenGround()
                .navigationTitle("Later")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    func count(for shortcut: HomeShortcut) -> Int {
        switch shortcut {
        // The store's unread threads, less the ones this device has opened or replied in.
        case .threads: threadReads.unseenCount(among: model.unreadThreads)
        // Reminders still waiting, live from the store.
        case .later: laterModel?.pending.count ?? 0
        // Live from the store, de-duplicated so a keystroke does not move the card.
        case .drafts: draftsModel.count
        }
    }

    /// Whether a card is asking to be dealt with *now* — see ``HomeShortcutCards/isCalling``.
    ///
    /// For Threads and Drafts that is still "is there anything in it": an unread thread and
    /// an unsent draft are both already overdue. Later is the one card whose contents have a
    /// *time* on them, so having three reminders says nothing about whether any of them wants
    /// attention yet — the owner asked for the colour only once one has come due.
    func isCalling(_ shortcut: HomeShortcut) -> Bool {
        switch shortcut {
        case .later: laterModel?.isDue ?? false
        case .threads, .drafts: HomeShortcutCard.hasSomethingWaiting(count(for: shortcut))
        }
    }

    func press(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .threads: showsThreads = ThreadsRoute()
        case .later: showsLater = LaterRoute()
        case .drafts: showsDrafts = DraftsRoute()
        }
    }

    /// Opens a screen the system asked for — see ``AppDestination``.
    ///
    /// Not ``press(_:)``. A card is tapped by somebody already looking at the sidebar, so it
    /// pushes onto whatever is there; an intent arrives from outside with no idea what is
    /// open, and landing *on top of* a conversation would give the reader a screen they have
    /// to undo before they can do anything else. So this pops first — the same conclusion
    /// the reminder alert reached, for the same reason.
    ///
    /// Idempotent on the screen being asked for: asking for Threads while Threads is already
    /// open leaves it exactly where it is rather than popping and re-pushing it, which would
    /// be a visible flinch for no change of destination.
    func open(_ destination: AppDestination) {
        openedThread = nil
        path = []
        if destination != .threads { showsThreads = nil }
        if destination != .later { showsLater = nil }
        if destination != .drafts { showsDrafts = nil }
        switch destination {
        case .threads: if showsThreads == nil { showsThreads = ThreadsRoute() }
        case .later: if showsLater == nil { showsLater = LaterRoute() }
        case .drafts: if showsDrafts == nil { showsDrafts = DraftsRoute() }
        }
    }

    /// A heading and the rows it introduces, in **one** list cell.
    ///
    /// One cell and not one per row: a `List` will not size a cell to nothing, so a section of
    /// rows that each kept their own cell could not close. ``SidebarAccordion`` holds the
    /// measurements and the rest of the reasoning.
    @ViewBuilder
    func sectionCell(_ section: SidebarSectionContent, resumable: String?) -> some View {
        let isExpanded = expansion(for: section.section).wrappedValue
        VStack(spacing: 0) {
            SidebarSectionHeader(
                section: section.section,
                count: section.count,
                isExpanded: expansion(for: section.section),
                // Channels and Direct Messages are the two things this app makes. A
                // `+` on Starred would be a second way to spell a star, and an agent
                // is not something made on the phone at all.
                create: create(for: section.section)
            )
            .padding(.horizontal, Self.headerInsetH)
            SidebarAccordion(isExpanded: isExpanded) {
                VStack(spacing: 0) {
                    if section.rows.isEmpty {
                        emptySectionLine(section.section)
                    } else {
                        rows(of: section, resumable: resumable)
                    }
                }
            }
        }
        // No spacing of its own: the heading and the rows hold theirs, and an inset here is one
        // the collapsed section could not give back.
        .listRowInsets(EdgeInsets())
        // No list rule: each heading draws its own, and ruled rows read as a form.
        .listRowSeparator(.hidden)
        // Clear and not nothing: a row given no background falls back to `systemBackground`.
        .listRowBackground(Color.clear)
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
                    // Inside the button, so the button's frame *is* `resumeMark`'s rectangle
                    // and the wash drawn behind it lands exactly there. The row's spacing used
                    // to be entirely `listRowInsets`, outside the button, which left the wash
                    // 8pt narrower on each side than the mark beside it — and a `Shape` that
                    // reached back out could not escape the cell's own inset container.
                    // See ``SidebarRowMetrics``.
                    .padding(.horizontal, SidebarRowMetrics.labelPaddingH)
                    .padding(.vertical, SidebarRowMetrics.labelPaddingV)
            }
            .buttonStyle(.hivePress(.row, in: .rect(cornerRadius: SidebarRowMetrics.radius, style: .continuous)))
            // Behind the button and no longer behind the cell, which the section now owns: the
            // same rectangle, and the wash and the mark are two `background`s on one view
            // rather than two drawings agreeing by arithmetic.
            .background { resumeMark(isResumable: row.id == resumable) }
            // Spoken, because the highlight is the only thing that says so and a colour
            // says nothing to VoiceOver. A hint rather than part of the label: it describes
            // a second way to get here, not what this row is.
            .accessibilityHint(row.id == resumable ? Self.resumeHint : "")
            // What the cell used to inset the row by — outside both drawings, so each keeps
            // the rectangle `SidebarRowMetrics` places it in.
            .padding(SidebarRowMetrics.rowInsets)
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
    /// A wash of the theme's row highlight behind the whole row rather than a bar, a dot or a
    /// badge: it has to be legible at a glance without competing with the two things this list
    /// already says with weight and colour — unread, and mentioned. A tinted row reads as *place*,
    /// which is what it means, and nothing else in the sidebar is trying to say that.
    ///
    /// Rounded to match the glyph beside it, and inset from the row by nothing at all: it is
    /// the `background` of the row's `Button`, whose frame ``SidebarRowMetrics`` already places
    /// where this rectangle belongs. It was the cell's `listRowBackground` and subtracted
    /// ``SidebarRowMetrics/insetH``/``SidebarRowMetrics/insetV`` itself to get there; the row
    /// has no cell of its own now that the section is one, so that spacing is real padding
    /// outside both drawings instead.
    @ViewBuilder
    func resumeMark(isResumable: Bool) -> some View {
        if isResumable {
            RoundedRectangle(cornerRadius: SidebarRowMetrics.radius, style: .continuous)
                .fill(PressFeedback.fillColor.opacity(SidebarRowMetrics.opacity))
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
}

// MARK: - Derivation

private extension ChannelListView {
    /// Opens one navigation request originating outside this view tree.
    ///
    /// The route itself is derived in ``ChannelListView/route(for:)`` — it reads nothing this
    /// view holds, and this file is six lines from swiftlint's `file_length` error.
    func open(_ target: AppTarget) {
        if case let .destination(destination) = target { return open(destination) }
        guard let route = Self.route(for: target) else { return }
        openNotification(route)
    }

    var notificationLocation: InAppNotificationLocation? {
        if let openedThread {
            return .thread(channelID: openedThread.channel, rootID: openedThread.root)
        }
        return path.last.map { .channel($0.channel.id) }
    }

    func openNotification(_ route: InAppNotificationRoute) {
        workspacePanel.setOpen(false)
        showAccount = false
        showsBrowseChannels = false
        showsCreateChannel = false
        showsNewDirectMessage = false
        showsDrafts = nil
        showsThreads = nil
        showsLater = nil

        switch route.location {
        case let .channel(channelID):
            openedThread = nil
            path = [ConversationRoute(
                channel: conversationRow(for: channelID, fallback: route.fallbackChannel)
            )]
        case let .thread(channelID, rootID):
            path = []
            openedThread = ThreadRoute(root: rootID, channel: channelID, anchor: .latestReply)
        }
    }

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

    func conversationRow(for channelID: String, fallback: ChannelListRow? = nil) -> ChannelListRow {
        Self.conversationRow(for: channelID, in: model.channels, fallback: fallback)
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
