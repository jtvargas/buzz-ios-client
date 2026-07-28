import BuzzKit
import SwiftUI

/// The sidebar (§8): Starred, Channels, Direct Messages, and Agents as expandable
/// sections of compact rows, live from the store, with the engine-state pill in the
/// toolbar. Tapping a conversation pushes its timeline; a swipe or a long press stars it.
///
/// # Why the app-wide environment lives here
///
/// This view is the only place *above* every pushed timeline, thread, and sheet, so it
/// is where the shared resolvers are injected: the `#channel` name→id map, the
/// name/avatar/conversation resolver, and the single clock behind relative timestamps.
/// All three are attached to the `NavigationStack` itself — above
/// `navigationDestination` — together with the four `.task`s that drive them. A value
/// injected *inside* the destination does not reach the pushed view, so moving any of
/// them down would silently cost every pushed surface its name resolution.
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
    /// The reader's starred conversations, on this device. Owned here because this view
    /// both groups by it and offers the action that changes it.
    @State private var starred = StarredConversations()
    /// How far this device has read into each thread. Owned here for the same reason the
    /// stars are: this view draws the number the marks subtract from, and it is the one
    /// place above both the Threads screen and the thread views that write them.
    @State private var threadReads = ThreadReadMarks()
    @State private var showAccount = false
    /// The Threads screen, when it is pushed. A value rather than a `Bool` so it goes
    /// through `navigationDestination(item:)` like every other push in the app.
    @State private var showsThreads: ThreadsRoute?
    /// The thread the **Threads screen** has open, hoisted out of ``ThreadsView`` to here.
    ///
    /// State in the wrong place, but for ``ChannelListTabBar``: this stack has to know about
    /// every push that hides the tab bar, and a `@State` inside ``ThreadsView`` is a push it
    /// cannot see. Only the storage moved — that screen still declares the destination. The
    /// thread a *conversation* opens needs no such move: by then `path` is non-empty and the
    /// bar is already hidden.
    @State private var openedThread: ThreadRoute?
    /// Whether the Later shortcut's "not built yet" notice is showing.
    @State private var showsLaterNotice = false
    /// The pushed conversations. An explicit path — rather than the implicit one
    /// `NavigationLink(value:)` drives — because opening a direct message has to push
    /// programmatically from a sheet that is already dismissing.
    ///
    /// Typed, and not a `NavigationPath`: `NavigationPath` cannot be read back, so
    /// "is this conversation already on the stack?" is not a question it can answer, and
    /// the answer is what stops a DM opened from inside itself stacking on itself
    /// (see ``ConversationRoute/pushed(onto:)``).
    @State private var path: [ConversationRoute] = []

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

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        _model = State(initialValue: ChannelListModel(store: store, selfPubkey: selfPubkey))
        _presence = State(initialValue: PresenceModel(store: engine.presenceStore))
        _directory = State(initialValue: EntityDirectoryModel(store: store))
        _router = State(initialValue: DirectMessageRouter(opener: engine))
    }

    var body: some View {
        // Derived once per pass and threaded down, so the resolver and the `#channel` map
        // are each built one time rather than once for the environment and again for the rows.
        let names = entityNames
        let channelNames = ChannelNameMap(channels: model.channels)

        NavigationStack(path: $path) {
            sidebar(names: names)
                // The heading every other screen carries, naming the workspace this app is
                // signed in to (§ ``CommunityIdentity``). It leads to the same account sheet
                // the face at the trailing edge does, and is the larger target.
                .conversationTitle(
                    mark: Self.communityMark,
                    // Derived from the stored relay URL where it is used rather than held in
                    // a model: it is the same string on every pass and on every launch, and
                    // an object whose only job is to hold a constant still has to be created,
                    // injected and driven for it.
                    title: CommunityIdentity.name(),
                    actionHint: "Double tap to show your account"
                ) {
                    showAccount = true
                }
                .navigationDestination(for: ConversationRoute.self) { route in
                    ChannelTimelineView(
                        channel: route.channel,
                        store: store,
                        engine: engine,
                        selfPubkey: environment.selfPubkeyHex,
                        knownPeer: route.knownPeer
                    )
                }
                .toolbar {
                    // Both at the trailing edge: the heading now holds the leading slot, and
                    // a second item there would push it towards the overflow menu the whole
                    // of ``ConversationTitleBar`` exists to stay out of.
                    ToolbarItem(placement: .topBarTrailing) {
                        EngineStatePill(state: environment.engineState)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAccount = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Account")
                    }
                }
                .sheet(isPresented: $showAccount) {
                    AccountView(store: store, engine: engine, selfPubkey: environment.selfPubkeyHex)
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
        // The app-wide `#channel` name→id map, built from the live channel list and
        // injected once here so every pushed timeline and thread resolves `#`-tokens
        // through the same source. Rebuilt only when the channel set changes.
        .environment(\.channelNameMap, channelNames)
        // The app-wide name/avatar/conversation resolver and the single clock behind
        // relative timestamps. Injected once here, above every pushed timeline,
        // thread, and sheet, so all of them name an identity identically (§4) and
        // age their timestamps off one tick (§7/§9).
        .environment(\.entityNames, names)
        .environment(\.relativeTimeTicker, ticker)
        // The device's per-thread read marks, injected above both the Threads screen that
        // reads them and the thread views that write them — so opening a thread from any
        // surface strikes it off the same count this view draws.
        .environment(\.threadReadMarks, threadReads)
        // Injected here, above the destination, because the sheet that *starts* a direct
        // message lives inside a pushed conversation while the navigation that *finishes*
        // it belongs to this stack.
        .environment(\.directMessageRouter, router)
        // Pressing a `#`-channel reference inside a message navigates to it. Injected
        // here for the same reason as the router above: the press happens in a pushed
        // timeline, the push belongs to this stack. Already-open conversations are left
        // alone by ``ConversationRoute/pushed(onto:)``, so pressing a reference to the
        // channel you are reading does nothing rather than stacking it on itself.
        .environment(\.openConversation, OpenConversationAction { channelID in
            let route = ConversationRoute(channel: conversationRow(for: channelID))
            path = route.pushed(onto: path)
        })
        // The router hands back an opened conversation once; this is the one place that
        // turns it into a push, and it clears the value so an unrelated body pass cannot
        // re-push the same conversation.
        .onChange(of: router.pendingConversation) { _, opened in
            guard let opened else { return }
            router.pendingConversation = nil
            let route = ConversationRoute(
                channel: conversationRow(for: opened.channelID),
                // The peer the relay named, carried only until the roster lands: it is
                // what lets a never-synced DM show the person's name instead of the
                // untitled placeholder.
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
        .task { await model.run() }
        .task { await presence.run() }
        .task { await directory.run() }
        .task { await ticker.run() }
    }

    /// The mark on the home heading: one cell of the honeycomb, for the workspace as a whole
    /// — neither a room (`#`) nor a person (a face). Filled rather than the outlined grid it
    /// was: the bar draws its mark small, where a mesh of hairlines reads as noise. Named so
    /// a test can check the system has it — a missing symbol renders as nothing, silently.
    static let communitySymbol = "hexagon.fill"

    /// The one heading drawn in the accent: the workspace's own name is what the colour is
    /// *for*, where every other heading names a conversation inside it. Held here rather than
    /// at the call site so a test can hold the rule.
    static let communityMark = ConversationTitleBar.Mark.symbol(communitySymbol, accented: true)
}

// MARK: - Content

private extension ChannelListView {
    /// One flat list: the shortcut cards, then a heading row and its conversations for each
    /// grouping. `List` keeps the rows lazy and recycled; `SidebarRow.id` (the channel's
    /// group id) keeps their identity stable as unread counts stream in, so a re-read
    /// updates rows instead of rebuilding them.
    ///
    /// Flat, and not a `Section` per heading, because a plain list **pins** section headers
    /// — see ``SidebarSectionHeader``. Everything else about the grouping is unchanged: the
    /// headings still expand and collapse, and each still draws the rule above it.
    @ViewBuilder
    func sidebar(names: EntityNames) -> some View {
        if model.channels.isEmpty {
            emptyState
        } else {
            List {
                shortcuts
                ForEach(sidebarContent(names: names).sections) { section in
                    SidebarSectionHeader(
                        section: section.section,
                        count: section.count,
                        isExpanded: expansion(for: section.section)
                    )
                    .listRowInsets(Self.headerInsets)
                    .listRowSeparator(.hidden)
                    if expansion(for: section.section).wrappedValue {
                        rows(of: section)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// The Threads and Later cards, in one row above the conversations.
    ///
    /// One list row holding both, rather than a row each: they are a set of destinations,
    /// and the first conversation heading below draws its rule because this is always above
    /// it.
    var shortcuts: some View {
        HomeShortcutCards(count: count(for:), press: press(_:))
            .listRowInsets(Self.cardsInsets)
            .listRowSeparator(.hidden)
    }

    func count(for shortcut: HomeShortcut) -> Int {
        switch shortcut {
        // The store's unread threads, less the ones already read on this device: opening a
        // thread (or replying in it) marks it, and the mark is what strikes it off here.
        case .threads: threadReads.unseenCount(among: model.unreadThreads)
        // Nothing is saved anywhere yet, so this is the truth rather than a placeholder.
        case .later: 0
        }
    }

    func press(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .threads: showsThreads = ThreadsRoute()
        case .later: showsLaterNotice = true
        }
    }

    func rows(of section: SidebarSectionContent) -> some View {
        ForEach(section.rows) { row in
            // No peer hint from here: a conversation reached from the sidebar is one the
            // channel list already knows, so its roster is in hand.
            NavigationLink(value: ConversationRoute(channel: row.channel)) {
                ChannelRowView(row: row, presence: presence)
            }
            .listRowInsets(Self.rowInsets)
            // No per-row rule: sections of ruled rows read as a form, not as one
            // navigation surface. The section headings do the separating.
            .listRowSeparator(.hidden)
            .swipeActions(edge: .leading, allowsFullSwipe: true) { starAction(row) }
            // The same action a second way. A swipe is the fast path for someone who
            // knows it is there; a long press is how anyone else finds it at all.
            .contextMenu { starAction(row) }
        }
    }

    /// Star or unstar one conversation. One definition, used by both the swipe and the
    /// context menu, so the two can never offer different words for the same action.
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

    @ViewBuilder
    var emptyState: some View {
        if model.hasLoaded {
            ContentUnavailableView(
                "No conversations yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Channels and direct messages appear here as they sync from the relay.")
            )
        } else {
            ProgressView()
        }
    }

    static let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
    static let headerInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    /// The cards sit slightly clear of the first heading's rule, which is the only thing
    /// between them and the conversations.
    static let cardsInsets = EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16)
}

// MARK: - Derivation

private extension ChannelListView {
    /// The resolver for this pass of the body: the live directory snapshot composed
    /// with the live channel list. Rebuilt only when one of those changes, and the
    /// rebuild is proportional to the identities that have *no* name (the ones whose
    /// short form has to be computed), not to the roster.
    var entityNames: EntityNames {
        EntityNames(
            snapshot: directory.snapshot,
            channels: model.channels,
            selfPubkey: environment.selfPubkeyHex
        )
    }

    /// The row to push for a channel the router just opened.
    ///
    /// The live list first, so one conversation is one row value wherever it was reached
    /// from. A freshly created DM may not be in that list yet: the relay publishes a
    /// channel's metadata *after* it commits the channel, so the id is authoritative
    /// before the name is. Rather than block navigation on a read-back that can lose that
    /// race, this synthesises the minimum row the destination needs — everything a reader
    /// sees is resolved by ``EntityNames``, from the roster once there is one and from the
    /// route's `knownPeer` until then.
    ///
    /// Keeping one instance of a conversation on the stack is
    /// ``ConversationRoute/pushed(onto:)``'s job, not this one's: two calls here can
    /// legitimately answer with the same row, and it is the push that decides what that
    /// means.
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
    /// Deliberately does **not** read the presence roster: presence is consulted inside
    /// each row instead, so a heartbeat invalidates the small views that draw a dot
    /// rather than re-deriving every section (§9).
    func sidebarContent(names: EntityNames) -> SidebarContent {
        SidebarContent.build(channels: model.channels, names: names, starred: starred.ids)
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
