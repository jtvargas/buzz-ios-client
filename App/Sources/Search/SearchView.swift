import BuzzKit
import SwiftUI

/// Local-first search with its own navigation stack and resolver scope.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: SearchModel
    @State private var query = ""
    @State private var path: [ConversationRoute] = []
    @State private var profilePeer: ProfilePeer?
    @State private var presence: PresenceModel
    @State private var ticker = RelativeTimeTicker()
    @State private var threadReads = ThreadReadMarks()
    @State private var router: DirectMessageRouter

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        _model = State(initialValue: SearchModel(store: store, selfPubkey: selfPubkey, engine: engine))
        _presence = State(initialValue: PresenceModel(store: engine.presenceStore))
        _router = State(initialValue: DirectMessageRouter(opener: engine))
    }

    private var entityNames: EntityNames {
        EntityNames(snapshot: model.directory, channels: model.channels, selfPubkey: selfPubkey)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(HomeTab.search.title)
                .navigationDestination(for: ConversationRoute.self) { route in
                    ChannelTimelineView(
                        channel: route.channel,
                        store: store,
                        engine: engine,
                        drafts: environment.drafts,
                        uploader: { environment.mediaUploader },
                        selfPubkey: selfPubkey,
                        knownPeers: route.knownPeers,
                        focusingComposer: route.focusesComposer
                    )
                }
        }
        .searchable(text: $query, prompt: "Search messages, people, and channels")
        .onChange(of: query) { _, value in model.search(value) }
        .onSubmit(of: .search) { model.submit(query) }
        .toolbar(ChannelListTabBar.visibility(conversations: path, openedThread: nil), for: .tabBar)
        .environment(\.entityNames, entityNames)
        .environment(\.channelNameMap, ChannelNameMap(channels: model.channels))
        .environment(\.relativeTimeTicker, ticker)
        .environment(\.threadReadMarks, threadReads)
        .environment(\.directMessageRouter, router)
        .environment(\.openConversation, OpenConversationAction { channelID in
            open(channelID: channelID)
        })
        .onChange(of: router.pendingConversation) { _, opened in
            guard let opened else { return }
            router.pendingConversation = nil
            let route = ConversationRoute(
                channel: channelRow(for: opened.channelID),
                knownPeers: opened.peers
            )
            path = route.pushed(onto: path)
        }
        .onChange(of: RecentPlaces.location(path: path, openedThread: nil), initial: true) { _, location in
            environment.recents.visit(location, in: environment.communities.activeID)
        }
        .profileSheet(peer: $profilePeer, presence: presence)
        .task { await presence.run() }
        .task { await ticker.run() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if !model.messages.isEmpty {
                Section("Messages") {
                    ForEach(model.messages) { hit in
                        SearchMessageRow(hit: hit, names: entityNames) {
                            open(message: hit)
                        }
                    }
                }
            }
            if !model.results.people.isEmpty {
                Section("People") {
                    ForEach(model.results.people) { hit in
                        SearchPersonRow(hit: hit, names: entityNames) {
                            profilePeer = ProfilePeer(pubkey: hit.person.pubkey)
                        }
                    }
                }
            }
            if !model.results.channels.isEmpty {
                Section("Channels") {
                    ForEach(model.results.channels) { hit in
                        SearchChannelRow(hit: hit) {
                            open(channel: hit.channel)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .hiveScreenGround()
        .overlay { stateOverlay }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if model.messages.isEmpty,
           model.results.people.isEmpty,
           model.results.channels.isEmpty,
           !model.isSearching {
            if let error = model.errorMessage {
                ContentUnavailableView(
                    "Search unavailable",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text(error)
                )
            } else if model.hasSearched {
                ContentUnavailableView.search(text: model.current)
            } else {
                ContentUnavailableView(
                    "Search",
                    systemImage: "magnifyingglass",
                    description: Text("Find messages, people, and channels.")
                )
            }
        }
    }

    private func open(message: SearchMessageResult) {
        let fallback = ChannelListRow(
            id: message.channelID,
            name: nil,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: message.createdAt,
            lastMessageID: message.id,
            lastMessageSnippet: message.content,
            lastMessageAuthor: message.authorName,
            lastMessageAuthorPubkey: message.pubkey,
            channelType: message.isDirectMessage ? "dm" : nil
        )
        open(channelID: message.channelID, fallback: fallback)
    }

    private func open(channel: BrowsableChannel) {
        let fallback = ChannelListRow(
            id: channel.id,
            name: channel.name,
            about: channel.about,
            picture: channel.picture,
            isPrivate: channel.isPrivate,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
        open(channelID: channel.id, fallback: fallback)
    }

    private func open(channelID: String, fallback: ChannelListRow? = nil) {
        let route = ConversationRoute(channel: channelRow(for: channelID, fallback: fallback))
        path = route.pushed(onto: path)
    }

    private func channelRow(for channelID: String, fallback: ChannelListRow? = nil) -> ChannelListRow {
        ChannelListView.conversationRow(for: channelID, in: model.channels, fallback: fallback)
    }
}
