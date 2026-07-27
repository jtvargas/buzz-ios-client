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
    @State private var showAccount = false
    /// The Threads screen, when it is pushed. A value rather than a `Bool` so it goes
    /// through `navigationDestination(item:)` like every other push in the app.
    @State private var showsThreads: ThreadsRoute?
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
        // Derived once per pass and threaded down, so the resolver and the `#channel`
        // map are each built one time rather than once for the environment and again
        // for the rows.
        let names = entityNames
        let channelNames = ChannelNameMap(channels: model.channels)

        NavigationStack(path: $path) {
            sidebar(names: names)
                .navigationTitle("Messages")
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
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showAccount = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Account")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        EngineStatePill(state: environment.engineState)
                    }
                }
                .sheet(isPresented: $showAccount) {
                    AccountView(store: store, engine: engine, selfPubkey: environment.selfPubkeyHex)
                }
                .navigationDestination(item: $showsThreads) { _ in
                    ThreadsView(store: store, engine: engine, selfPubkey: environment.selfPubkeyHex)
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
}

// MARK: - Content

private extension ChannelListView {
    /// One list, one section per heading, no card per row. `List` keeps the rows lazy and
    /// recycled; `SidebarRow.id` (the channel's group id) keeps their identity stable
    /// as unread counts stream in, so a re-read updates rows instead of rebuilding them.
    @ViewBuilder
    func sidebar(names: EntityNames) -> some View {
        if model.channels.isEmpty {
            emptyState
        } else {
            List {
                shortcuts
                ForEach(sidebarContent(names: names).sections) { section in
                    Section {
                        if expansion(for: section.section).wrappedValue {
                            rows(of: section)
                        }
                    } header: {
                        SidebarSectionHeader(
                            section: section.section,
                            count: section.count,
                            isExpanded: expansion(for: section.section)
                        )
                        .listRowInsets(Self.headerInsets)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(.compact)
        }
    }

    /// The Threads and Later shortcuts, in a headerless section above the conversations.
    ///
    /// A section of their own rather than rows inside the first one: they are not
    /// conversations, and a heading over them would have to claim they are. Every
    /// conversation heading below draws its rule because this section is always above it.
    var shortcuts: some View {
        Section {
            ForEach(HomeShortcut.allCases) { shortcut in
                Button { press(shortcut) } label: {
                    HomeShortcutRow(shortcut: shortcut, count: count(for: shortcut))
                }
                .buttonStyle(.plain)
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.hidden)
            }
        }
    }

    func count(for shortcut: HomeShortcut) -> Int? {
        let count = switch shortcut {
        case .threads: model.newThreadCount
        // Nothing is saved anywhere yet, so this is the truth rather than a placeholder.
        case .later: 0
        }
        return shortcut.showsCount(count) ? count : nil
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

/// One pushed conversation: the row its timeline renders, and — when the push came from
/// opening a direct message — the peer the relay said it is with.
///
/// A route type rather than the bare ``BuzzKit/ChannelListRow`` the sidebar pushes,
/// because the two ways into a conversation know different things about it. From the
/// sidebar the roster is already read, so the row is the whole story. From a profile
/// sheet's Message action the channel is seconds old and its roster is still in flight, so
/// the peer travels with the push (see ``OpenedConversation``).
struct ConversationRoute: Hashable {
    let channel: ChannelListRow
    /// The peer this conversation was just opened with, or `nil` when the roster is the
    /// only thing that should name it.
    var knownPeer: String?
}

extension ConversationRoute {
    /// `path` with this conversation opened: exactly one instance of it, on top.
    ///
    /// Pure so the rule is tested rather than driven through a navigation stack.
    ///
    /// A plain append is wrong here because the tap that opens a conversation is reachable
    /// from *inside* that same conversation: the peer's face is on every row of a DM, and
    /// their profile sheet offers Message. Appending there pushed a second copy of the
    /// conversation onto the first, so backing out of a DM went through an identical DM.
    /// Already-on-top is left completely alone rather than replaced, because re-assigning
    /// the same conversation as a *different* element value is a pop-and-push the reader
    /// would watch happen.
    func pushed(onto path: [ConversationRoute]) -> [ConversationRoute] {
        guard path.last?.channel.id != channel.id else { return path }
        var updated = path.filter { $0.channel.id != channel.id }
        updated.append(self)
        return updated
    }
}
