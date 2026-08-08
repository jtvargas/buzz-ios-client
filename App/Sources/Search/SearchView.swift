import BuzzKit
import SwiftUI

/// Local-first message search with its own navigation stack and resolver scope.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: SearchModel
    @State private var query = ""
    /// Everything this stack has pushed, conversations and threads alike — see
    /// ``SearchRoute`` for why a thread is an element here rather than a binding beside it.
    @State private var path: [SearchRoute] = []
    /// The result whose tap has not yet produced a screen. Drawn as a spinner on that row,
    /// and cleared by the destination's own `onAppear`, so it covers exactly the gap between
    /// the finger and the answer and never outlives it.
    @State private var opening: String?
    @State private var history = SearchHistory()
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
                .navigationDestination(for: SearchRoute.self) { route in
                    destination(for: route)
                        // The tap has produced a screen, so the row that answered it can stop
                        // saying it is working on one.
                        .onAppear { opening = nil }
                }
        }
        .searchable(text: $query, prompt: "Search messages")
        .searchFocused($isFieldFocused)
        .onChange(of: query) { _, value in model.search(value) }
        .onSubmit(of: .search) {
            model.submit(query)
            // Filed here and where a result is opened, and nowhere else. Recording every
            // debounced lookup would fill the history with the prefixes of one word — these
            // two are the moments the reader said the term was the one they meant.
            history.record(query)
            // Submitting is the reader saying they are done typing. Holding the keyboard
            // up after it hides the top of their own results.
            isFieldFocused = false
        }
        // From the path alone, because the path is now the whole stack. Declared here rather
        // than on the pushed views for ``ChannelListTabBar``'s measured reason.
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
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
            path = SearchRoute.conversation(route).pushed(onto: path)
        }
        .onChange(
            of: RecentPlaces.location(path: path.conversations, openedThread: path.openedThread),
            initial: true
        ) { _, location in
            environment.recents.visit(location, in: environment.communities.activeID)
        }
        // The history is per community, like the places the reader has visited. Driven from
        // here rather than read at init: the active community is not resolved when this view
        // is constructed, and it changes underneath a screen that is never rebuilt.
        .onChange(of: environment.communities.activeID, initial: true) { _, id in
            history.activate(community: id)
        }
        .task { await ticker.run() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            ForEach(model.messages) { hit in
                SearchMessageRow(hit: hit, names: entityNames, isOpening: opening == hit.id) {
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
                ZStack(alignment: .bottom) {
                    stateOverlay
                    hideKeyboardButton
                }
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
        } else if model.messages.isEmpty, showsRecentSearches {
            // Inside `dismissesKeyboard` like every other state. A child `Button` wins a tap
            // over an ancestor's `onTapGesture`, so the rows keep their own taps and every
            // *other* point on the screen puts the keyboard away — which is what the owner
            // asked for, and what the empty space below two rows is otherwise good for.
            RecentSearchesView(history: history) { term in
                // The field takes the term as well as the search, so the reader lands on
                // their own words and can edit from there instead of retyping to change a
                // letter.
                query = term
                model.submit(term)
                history.record(term)
                isFieldFocused = false
            }
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

    /// What the screen says when it has no rows to show.
    ///
    /// It carried the `Done` button too, until the affordance became a floating one that
    /// every state has — see ``hideKeyboardButton``.
    @ViewBuilder
    private var emptyState: some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(error)
            }
        } else if model.hasSearched {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("No message matches “\(model.current)”.")
            }
        } else {
            ContentUnavailableView {
                Label("Search messages", systemImage: "magnifyingglass")
            } description: {
                Text("Find any message in the conversations you are in.")
            }
        }
    }

    /// Whether the screen has nothing to say yet *and* something to remember.
    ///
    /// Not `query.isEmpty`: a one-letter query is below the search floor and produces no
    /// lookup at all, so the reader is still looking at a screen that has asked nothing. What
    /// decides is whether a search has run — which ``SearchModel`` already answers, and
    /// answers `false` again the moment the field is cleared.
    private var showsRecentSearches: Bool {
        model.errorMessage == nil && !model.hasSearched && !history.terms.isEmpty
    }

    /// The way out of the keyboard, floating just above it.
    ///
    /// # Why it is not a keyboard toolbar
    ///
    /// Because a `ToolbarItem(placement: .keyboard)` renders nothing at all on this screen,
    /// verified on device: the field belongs to the **tab bar**, which is outside this stack's
    /// toolbar scope, so there is no accessory bar of ours for an item to attach to. This is
    /// the same reason `Done` had to live inside the empty state's own content.
    ///
    /// It floats here instead of in that content because the content is no longer always a
    /// placeholder — the recent searches fill the screen — and an affordance that exists in
    /// one state and not the others is one the reader has to learn twice. Positioned by the
    /// same arithmetic as ``stateOverlay``: inside a frame the bottom safe area has already
    /// been taken off, which is where the keyboard is not.
    @ViewBuilder
    private var hideKeyboardButton: some View {
        if isFieldFocused {
            Button {
                isFieldFocused = false
            } label: {
                Label("Hide", systemImage: "keyboard.chevron.compact.down")
                    .font(.hive(.caption, weight: .semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .clipShape(.capsule)
            .padding(.bottom, 10)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// The screen a route names.
    @ViewBuilder
    private func destination(for route: SearchRoute) -> some View {
        switch route {
        case let .conversation(route):
            ChannelTimelineView(
                channel: route.channel,
                store: store,
                engine: engine,
                drafts: environment.drafts,
                uploader: { environment.mediaUploader },
                selfPubkey: selfPubkey,
                knownPeers: route.knownPeers,
                focusingComposer: route.focusesComposer,
                focusing: route.focus
            )
        case let .thread(route):
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

    /// Opens the surface the message is actually on, and asks that surface to land on it.
    ///
    /// A non-broadcast reply is deliberately excluded from its channel's page — see the
    /// `NOT EXISTS` against `thread` in BuzzKit's timeline query — so opening the channel for
    /// one pushes a screen it can never appear in, and the landing would page the entire
    /// channel back looking for a row that is not in it. Its thread is where it lives.
    ///
    /// Straight to the thread rather than through its channel: Back belongs to the results the
    /// reader is working through, not to a channel nobody asked for.
    private func open(message: SearchMessageResult) {
        opening = message.id
        // A term that led somewhere is a term worth remembering, whether or not the reader
        // ever pressed return on it.
        history.record(model.current)
        if let root = message.threadRootID {
            let route = ThreadRoute(
                root: root, channel: message.channelID, anchor: .reply(message.id)
            )
            path = SearchRoute.thread(route).pushed(onto: path)
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
        open(
            channelID: message.channelID,
            fallback: fallback,
            focusing: ConversationFocus(messageID: message.id, sentAt: message.createdAt)
        )
    }

    private func open(
        channelID: String,
        fallback: ChannelListRow? = nil,
        focusing focus: ConversationFocus? = nil
    ) {
        // Deliberately does *not* clear focus. A push already resigns the field, and
        // forcing the state false on the way out left the field unable to take the keyboard
        // back when the reader returned to it.
        let route = ConversationRoute(
            channel: channelRow(for: channelID, fallback: fallback),
            focus: focus
        )
        path = SearchRoute.conversation(route).pushed(onto: path)
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
