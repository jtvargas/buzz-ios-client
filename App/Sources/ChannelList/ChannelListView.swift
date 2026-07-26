import BuzzKit
import SwiftUI

/// The sidebar (§8): Channels, Direct Messages, and Agents as expandable sections of
/// compact rows, live from the store, with the engine-state pill in the toolbar.
/// Tapping a conversation pushes its timeline.
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
    @State private var showAccount = false
    /// The pushed conversations. An explicit path — rather than the implicit one
    /// `NavigationLink(value:)` drives — because opening a direct message has to push
    /// programmatically from a sheet that is already dismissing.
    @State private var path = NavigationPath()

    // Expansion persists across launches, one `UserDefaults` flag per section. The keys
    // come from ``SidebarSection/expansionStorageKey`` so the view and the tests that
    // pin those strings cannot drift apart.
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
            sidebar(names: names, channelNames: channelNames)
                .navigationTitle("Messages")
                .navigationDestination(for: ChannelListRow.self) { channel in
                    ChannelTimelineView(
                        channel: channel,
                        store: store,
                        engine: engine,
                        selfPubkey: environment.selfPubkeyHex
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
        // The router hands back a channel id once; this is the one place that turns it
        // into a push, and it clears the value so an unrelated body pass cannot re-push
        // the same conversation.
        .onChange(of: router.pendingChannelID) { _, channelID in
            guard let channelID else { return }
            router.pendingChannelID = nil
            path.append(conversationRow(for: channelID))
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
    /// One list, three sections, no card per row. `List` keeps the rows lazy and
    /// recycled; `SidebarRow.id` (the channel's group id) keeps their identity stable
    /// as previews and unread counts stream in, so a re-read updates rows instead of
    /// rebuilding them.
    @ViewBuilder
    func sidebar(names: EntityNames, channelNames: ChannelNameMap) -> some View {
        if model.channels.isEmpty {
            emptyState
        } else {
            List {
                ForEach(sidebarContent(names: names, channelNames: channelNames).sections) { section in
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

    func rows(of section: SidebarSectionContent) -> some View {
        ForEach(section.rows) { row in
            NavigationLink(value: row.channel) {
                ChannelRowView(row: row, presence: presence)
            }
            .listRowInsets(Self.rowInsets)
            // No per-row rule: three sections of ruled rows read as a form, not as one
            // navigation surface. Spacing and the section headings do the separating.
            .listRowSeparator(.hidden)
        }
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
    /// The live list first — pushing the row the sidebar already holds keeps one identity
    /// for one conversation, so navigating to a DM twice does not stack two destinations.
    /// A freshly created DM may not be in that list yet: the relay publishes a channel's
    /// metadata *after* it commits the channel, so the id is authoritative before the
    /// name is. Rather than block navigation on a read-back that can lose that race, this
    /// synthesises the minimum row the destination needs — everything a reader sees is
    /// resolved from the roster by ``EntityNames`` anyway, which for a two-member DM is
    /// the peer's own name.
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
    func sidebarContent(names: EntityNames, channelNames: ChannelNameMap) -> SidebarContent {
        SidebarContent.build(
            channels: model.channels,
            names: names,
            channelNames: channelNames,
            mentions: { model.mentions(for: $0) }
        )
    }

    /// The persisted expansion flag for a section.
    func expansion(for section: SidebarSection) -> Binding<Bool> {
        switch section {
        case .channels: $channelsExpanded
        case .directMessages: $directMessagesExpanded
        case .agents: $agentsExpanded
        }
    }
}
