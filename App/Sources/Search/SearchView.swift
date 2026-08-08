import BuzzKit
import SwiftUI

/// Local-first message search with its own navigation stack and resolver scope.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: SearchModel
    @State private var query = ""
    @State private var path: [ConversationRoute] = []
    /// A thread opened straight from a result, as ``ActivityView`` opens one from a
    /// notification: a reply is not reachable inside its channel, so the thread is where the
    /// result lives and Back belongs to the results rather than to a channel nobody asked for.
    @State private var openedThread: ThreadRoute?
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
                        focusingComposer: route.focusesComposer,
                        focusing: route.focusMessageID
                    )
                }
                .navigationDestination(item: $openedThread) { route in
                    ThreadView(
                        root: route.root,
                        channel: route.channel,
                        store: store,
                        engine: engine,
                        drafts: environment.drafts,
                        uploader: { environment.mediaUploader },
                        selfPubkey: selfPubkey,
                        landingOn: route.anchor
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
        .toolbar(
            ChannelListTabBar.visibility(conversations: path, openedThread: openedThread),
            for: .tabBar
        )
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
        .overlay {
            // Centred inside the bottom safe area rather than inside the frame. Which of
            // the two the keyboard actually shrinks here is not something to assume — the
            // bottom `safeAreaInset` this replaced was reported drawing *under* the keys —
            // and subtracting the inset is correct either way: it is the keyboard's height
            // when the frame runs behind it and about zero when the frame already stops
            // above it.
            GeometryReader { proxy in
                stateOverlay
                    .frame(
                        width: proxy.size.width,
                        height: max(0, proxy.size.height - proxy.safeAreaInsets.bottom)
                    )
            }
        }
    }

    /// The list's one non-row state: searching, failed, empty, or not yet asked.
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

    /// The empty screen, and the one place a `Done` can be *seen*.
    ///
    /// A `.keyboard`-placement toolbar item renders nothing for a search-role tab's field:
    /// that field is presented by the tab bar, outside this stack's toolbar scope. Verified
    /// on device — the row never appeared. So the affordance lives in the only content this
    /// screen draws while there is nothing to scroll, which is also the state that has no
    /// other way out.
    @ViewBuilder
    private var emptyState: some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(error)
            } actions: {
                dismissKeyboardButton
            }
        } else if model.hasSearched {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("No message matches “\(model.current)”.")
            } actions: {
                dismissKeyboardButton
            }
        } else {
            ContentUnavailableView {
                Label("Search messages", systemImage: "magnifyingglass")
            } description: {
                Text("Find any message in the conversations you are in.")
            } actions: {
                dismissKeyboardButton
            }
        }
    }

    @ViewBuilder
    private var dismissKeyboardButton: some View {
        if isFieldFocused {
            Button("Done") { isFieldFocused = false }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Opens the surface the message is actually on, and asks that surface to land on it.
    ///
    /// A non-broadcast reply is deliberately excluded from its channel's page — see the
    /// `NOT EXISTS` against `thread` in BuzzKit's timeline query — so opening the channel for
    /// one pushes a screen it can never appear in, and the landing would page the entire
    /// channel back looking for a row that is not in it. Its thread is where it lives.
    ///
    /// Straight to the thread rather than through its channel, which is ``ActivityView``'s
    /// rule for the same shape: Back belongs to the results the reader is working through.
    private func open(message: SearchMessageResult) {
        if let root = message.threadRootID {
            openedThread = ThreadRoute(
                root: root, channel: message.channelID, anchor: .reply(message.id)
            )
            return
        }
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
        open(channelID: message.channelID, fallback: fallback, focusing: message.id)
    }

    private func open(
        channelID: String,
        fallback: ChannelListRow? = nil,
        focusing focusMessageID: String? = nil
    ) {
        // Deliberately does *not* clear focus. A push already resigns the field, and
        // forcing the state false on the way out left the field unable to take the keyboard
        // back when the reader returned to it.
        let route = ConversationRoute(
            channel: channelRow(for: channelID, fallback: fallback),
            focusMessageID: focusMessageID
        )
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
