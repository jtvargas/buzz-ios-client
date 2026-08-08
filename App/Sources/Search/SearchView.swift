import BuzzKit
import SwiftUI

/// Local-first message search with its own navigation stack and resolver scope.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: SearchModel
    @State private var query = ""
    @State private var path: [ConversationRoute] = []
    @State private var ticker = RelativeTimeTicker()
    @State private var threadReads = ThreadReadMarks()
    @State private var router: DirectMessageRouter
    /// This screen presents no keyboard of its own and the search role's field ships no
    /// Cancel button, so the field's focus is the only handle on the keyboard there is.
    @FocusState private var isFieldFocused: Bool

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        _model = State(initialValue: SearchModel(store: store, selfPubkey: selfPubkey, engine: engine))
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
        .searchable(text: $query, prompt: "Search messages")
        .searchFocused($isFieldFocused)
        .onChange(of: query) { _, value in model.search(value) }
        .onSubmit(of: .search) {
            model.submit(query)
            // Submitting is the reader saying they are done typing. Holding the keyboard
            // up after it hides the top of their own results.
            isFieldFocused = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFieldFocused = false }
            }
        }
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
        .task { await ticker.run() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            ForEach(model.messages) { hit in
                SearchMessageRow(hit: hit, names: entityNames) {
                    open(message: hit)
                }
                // Clear and not nothing: a row given no background falls back to
                // `systemBackground`, which is pure black against this screen's
                // `#141414` ground — every result would read as a band.
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // The keyboard covers the results it is producing. Dragging the list is the
        // gesture a reader already reaches for; `Done` and the tap below cover the
        // states where there is nothing to drag.
        .scrollDismissesKeyboard(.immediately)
        .hiveScreenGround()
        .overlay { stateOverlay }
    }

    /// The list's one non-row state: searching, failed, empty, or not yet asked.
    ///
    /// Centred in the list's own bounds, which the keyboard insets — so the spinner sits
    /// in the middle of what the reader can actually see rather than under the keys.
    @ViewBuilder
    private var stateOverlay: some View {
        if model.isSearching, model.messages.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dismissesKeyboard($isFieldFocused)
        } else if model.messages.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dismissesKeyboard($isFieldFocused)
        } else if model.isSearching {
            // Results are already on screen and a newer answer is still coming. A floating
            // pill says so without displacing the rows or blocking a tap on one.
            ProgressView()
                .controlSize(.small)
                .padding(12)
                .background(.regularMaterial, in: .circle)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
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
                "Search messages",
                systemImage: "magnifyingglass",
                description: Text("Find any message in the conversations you are in.")
            )
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

    private func open(channelID: String, fallback: ChannelListRow? = nil) {
        // Dropped here rather than on the way back: focus survives a push, so a reader
        // returning from a conversation would otherwise land on a raised keyboard they
        // never asked for.
        isFieldFocused = false
        let route = ConversationRoute(channel: channelRow(for: channelID, fallback: fallback))
        path = route.pushed(onto: path)
    }

    private func channelRow(for channelID: String, fallback: ChannelListRow? = nil) -> ChannelListRow {
        ChannelListView.conversationRow(for: channelID, in: model.channels, fallback: fallback)
    }
}

private extension View {
    /// Puts the search field's keyboard away when this view is tapped.
    ///
    /// Only ever applied to a state view standing in for an empty list. Over live rows a
    /// tap gesture would compete with the row buttons for the same touch.
    func dismissesKeyboard(_ focus: FocusState<Bool>.Binding) -> some View {
        contentShape(.rect)
            .onTapGesture { focus.wrappedValue = false }
    }
}
