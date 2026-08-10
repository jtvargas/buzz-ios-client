import BuzzKit
import SwiftUI

/// The Activity tab: everything addressed to you, one row per conversation, filtered by a
/// chip rail.
///
/// # The bug this screen exists to not have
///
/// The Flutter client renders **one row per event**, so nine replies from one agent in one
/// thread arrive as nine near-identical rows saying "Mention Jarvis" — which is what JT was
/// looking at when he asked for this. Nothing is wrong with its data; the grouping is
/// missing. Desktop groups by conversation and shows a count
/// (`desktop/src/features/home/lib/inbox.ts`, `buildInboxItems`), and so does this: nine
/// replies cost one row, one glance, and one tap.
///
/// # Its own stack, and the resolvers that has to carry
///
/// This tab owns a `NavigationStack` separate from the sidebar's, so a conversation opened
/// from here backs out to *here* rather than to the channel list. That is the whole point of
/// an activity screen — you came to clear a list and you want to return to it.
///
/// The cost is that the app-wide values ``ChannelListView`` injects into *its* stack do not
/// reach this one, and a value attached inside a `navigationDestination` never reaches the
/// pushed view. The Activity **rows** genuinely do not need them — the feed read resolves
/// author names and avatars in SQL — but everything a row *pushes* does:
/// ``ChannelTimelineView``, ``ThreadView`` and ``TimelineRowView`` all read `entityNames`,
/// and `TimelineRowView` also reads `channelNameMap` and `openConversation`. Without them a
/// conversation opened from here would draw every author as a short key and render its
/// `#channel` and `@mention` pills dead — while the identical screen reached from the
/// sidebar worked. So the same five are injected here.
///
/// They are read inside ``ActivityModel``'s existing observation rather than by standing up
/// a second ``EntityDirectoryModel`` and ``ChannelListModel``: that observation already
/// re-runs on every relevant commit, so this costs two more reads instead of two more
/// observations over the same tables. `openConversation` cannot be shared in any case — it
/// pushes onto *this* stack, and a shared one would push onto the sidebar's.
///
/// The tidier end state is to hoist the shared models above the `TabView` in ``RootView``
/// and leave only the per-stack actions here. Not done in this change: the sidebar owns
/// those models today and it is a screen with four just-shipped features on it.
struct ActivityView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: ActivityModel
    @State private var filter: ActivityFilter = .all
    /// This tab's clock, for the ages-as-you-watch timestamps on the rows. Optional in the
    /// environment and `nil` by default, so without this the rows would format correctly
    /// once and then freeze — see ``EnvironmentValues/relativeTimeTicker``.
    @State private var ticker = RelativeTimeTicker()
    /// The conversations pushed from here. Typed rather than a `NavigationPath` for the
    /// reason ``ChannelListView`` gives: the path has to be *readable* for
    /// ``ConversationRoute/pushed(onto:)`` to keep a conversation off its own stack.
    @State private var path: [AppRoute] = []
    /// This device's per-thread read marks. Its own instance rather than the sidebar's:
    /// ``ThreadReadMarks`` persists to `UserDefaults`, so both tabs read and write the same
    /// storage and a thread read in one is read in the other on the next pass.
    @State private var threadReads = ThreadReadMarks()
    /// Opens a direct message from a profile sheet presented inside this stack.
    @State private var router: DirectMessageRouter

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        _model = State(initialValue: ActivityModel(store: store, selfPubkey: selfPubkey))
        _router = State(initialValue: DirectMessageRouter(opener: engine))
    }

    /// The name/avatar/conversation resolver for everything beneath this tab, rebuilt only
    /// when the directory or the channel set moves — ``ActivityModel`` guards both.
    private var entityNames: EntityNames {
        EntityNames(snapshot: model.directory, channels: model.channels, selfPubkey: selfPubkey)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .conversationTitle(mark: .glyph(Self.glyph), title: HomeTab.activity.title)
                // The same pull the sidebar and the Threads screen offer. This screen
                // summarises every channel, so a stale one misleads here exactly as much.
                .refreshable { await engine.refresh() }
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        // The same rule the sidebar's stack applies, through the same function: a reading
        // surface with a composer gets the full height, a list keeps the bar.
        .toolbar(
            ChannelListTabBar.visibility(path: path),
            for: .tabBar
        )
        // Injected on the stack rather than inside it, because a value attached below
        // `navigationDestination` never reaches the pushed view — the trap
        // ``ChannelListView`` documents at length, and the one that would otherwise leave a
        // conversation opened from this tab drawing every author as a bare key.
        .environment(\.entityNames, entityNames)
        .environment(\.channelNameMap, ChannelNameMap(channels: model.channels))
        .environment(\.relativeTimeTicker, ticker)
        .environment(\.threadReadMarks, threadReads)
        .environment(\.directMessageRouter, router)
        .environment(\.pushRoute, PushRouteAction { route in
            path = route.pushed(onto: path)
        })
        // Pushes onto *this* stack, which is why this one cannot be shared with the sidebar
        // however the others are resolved: pressing a `#channel` pill inside a conversation
        // opened from Activity must open it here, not behind the Home tab.
        .environment(\.openConversation, OpenConversationAction { channelID in
            path = AppRoute.conversation(
                ConversationRoute(channel: channelRow(for: channelID))
            ).pushed(onto: path)
        })
        // The router hands back an opened conversation once; clearing it is what stops an
        // unrelated body pass re-pushing. Same contract as the sidebar's.
        .onChange(of: router.pendingConversation) { _, opened in
            guard let opened else { return }
            router.pendingConversation = nil
            let route = ConversationRoute(
                channel: channelRow(for: opened.channelID),
                knownPeers: opened.peers
            )
            path = AppRoute.conversation(route).pushed(onto: path)
        }
        .onChange(of: path) { previous, current in
            guard let route = current.revealedConversation(after: previous) else { return }
            Task { await engine.setActiveChannel(route.channel.id) }
        }
        // This tab is a way *into* a conversation as much as the sidebar is, so a place
        // reached from here is a place visited. The same shared derivation and the same
        // shared list the sidebar writes to — see ``RecentPlaces``.
        .onChange(
            of: RecentPlaces.location(path: path),
            initial: true
        ) { _, location in
            environment.recents.visit(location, in: environment.communities.activeID)
        }
        .task { await model.run() }
        .task { await ticker.run() }
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.entries(matching: filter)
        VStack(spacing: 0) {
            ActivityFilterRail(selection: $filter, unreadCount: unreadConversations)
            List {
                ForEach(rows) { entry in
                    ActivityRow(entry: entry, unreadCount: unreadCount(for: entry)) { open(entry) }
                        .listRowInsets(ActivityRowMetrics.rowInsets)
                        // No rule between rows — the space separates them, the same call
                        // ``ThreadsView`` makes. A hairline under every row turns a list of
                        // summaries into a form.
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState(isFiltered: filter != .all, isEmpty: rows.isEmpty) }
        }
        // The rail and the list together, so the filter chips sit on the same ground the
        // rows do rather than on a strip of their own.
        .hiveScreenGround()
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
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
                landingOn: route.anchor,
                focusingComposer: route.focusesComposer
            )
        case .threads, .later, .drafts, .rescheduling:
            EmptyView()
        }
    }

    /// Two different empty states, because they mean two different things and the wrong one
    /// is actively misleading: "nothing has mentioned you" on a workspace that has mentioned
    /// you forty times, said only because the Action chip happens to be selected, reads as
    /// data loss.
    @ViewBuilder
    private func emptyState(isFiltered: Bool, isEmpty: Bool) -> some View {
        if model.hasLoaded, isEmpty {
            if isFiltered {
                // The long form, because the short one takes a system symbol name and this
                // mark is the app's own drawing now.
                ContentUnavailableView {
                    Label {
                        Text("Nothing under \(filter.title)")
                    } icon: {
                        GlyphView(Self.glyph, height: 48, relativeTo: .largeTitle)
                    }
                } description: {
                    Text("Other activity may be waiting under the chips above.")
                }
            } else {
                ContentUnavailableView(
                    "You're all caught up",
                    systemImage: "checkmark.circle",
                    description: Text("Mentions, replies and agent updates land here.")
                )
            }
        }
    }

    /// What a row should actually show as unread, after this device's own thread marks.
    ///
    /// # Why the store's count is not the answer on its own
    ///
    /// ``BuzzKit/ActivityEntry/unreadCount`` counts against the channel's NIP-RS read
    /// frontier, and **nothing in this app advances that frontier for a thread**. The only
    /// writer is ``ChannelTimelineModel/markReadIfNeeded()``; ``ThreadView`` deliberately
    /// writes only a device-local mark instead, because NIP-RS keys read state by channel
    /// and advancing it there would mark every other message in the channel read along with
    /// the thread (see ``ThreadReadMarks``).
    ///
    /// So without this, tapping a threaded row, reading it, and coming back left the pill
    /// and the chip badge exactly as they were — permanently. The same thread read as
    /// *read* on the Threads screen, which already consults these marks
    /// (``ThreadsView/isUnseen(_:)``), and *3 unread* here. Threaded rows are the common
    /// case on this workspace, so the counts JT asked for would have been wrong for most of
    /// the list, in the one way a reader cannot dismiss.
    ///
    /// `entry.latest.createdAt` is the right thing to compare because this feed excludes
    /// your own events — so the newest event in the conversation is by definition the newest
    /// one *by somebody else*, which is exactly what
    /// ``ThreadReadMarks/hasUnseen(_:latestReplyByOthersAt:)`` asks for.
    ///
    /// Known and deliberate on the other side: a non-threaded row opens the channel, whose
    /// frontier *does* advance, so reading one mention marks every top-level row in that
    /// channel read at once. That is how channel read state works everywhere in this app —
    /// the sidebar's badge included — and making Activity disagree with it would be a
    /// second answer to the same question.
    private func unreadCount(for entry: ActivityEntry) -> Int {
        guard entry.unreadCount > 0 else { return 0 }
        // A direct message is keyed on its channel, not on a thread
        // (``BuzzKit/ActivityFeedRead/Candidate/conversationID``), while `rootID` comes from
        // whichever event happens to be newest. So a DM whose latest message sits in a
        // thread would otherwise have its **whole** count gated on that one thread's mark —
        // read the thread, and messages outside it silently stop counting. The channel
        // frontier is the only honest answer for a conversation keyed by channel.
        guard !entry.isDirectMessage else { return entry.unreadCount }
        guard let rootID = entry.rootID else { return entry.unreadCount }
        return threadReads.hasUnseen(rootID, latestReplyByOthersAt: entry.latest.createdAt)
            ? entry.unreadCount
            : 0
    }

    /// How many conversations under a chip still hold something unseen — the number the chip
    /// wears. Computed here rather than on the model because only this layer can see the
    /// device-local thread marks; a badge counted without them would disagree with the rows
    /// directly beneath it.
    private func unreadConversations(matching filter: ActivityFilter) -> Int {
        model.entries.lazy.filter { filter.matches($0) && unreadCount(for: $0) > 0 }.count
    }

    /// Open what a row is about.
    ///
    /// A threaded row opens its thread; anything else opens the channel it happened in. The
    /// anchor is the one place unread state changes where you land: a thread with something
    /// new in it opens at the newest reply, because you came to catch up, and one you have
    /// already read opens at its opener, because you came to remember what it was about.
    ///
    /// Landing on a *particular* older message is deliberately not attempted — the app
    /// cannot navigate to an arbitrary message yet (that is the parked deep-link work), and
    /// approximating it by scrolling to a guess is worse than opening at a known position.
    private func open(_ entry: ActivityEntry) {
        guard let channelID = entry.channelID else { return }
        if let rootID = entry.rootID {
            path.append(.thread(ThreadRoute(
                root: rootID,
                channel: channelID,
                // The effective count, not the store's — a thread already read on this
                // device should open at what it is about, not at its end.
                anchor: unreadCount(for: entry) > 0 ? .latestReply : .opener
            )))
        } else {
            let row = channelRow(for: channelID, fallback: entry)
            path = AppRoute.conversation(ConversationRoute(channel: row)).pushed(onto: path)
        }
    }

    /// The channel a row opens.
    ///
    /// The real cached row when the workspace has one — which, now that this screen reads
    /// the channel list for its resolvers, is the ordinary case. The fallback is the same
    /// shape ``ChannelListView/conversationRow(for:)`` builds for an uncached channel; it
    /// exists because the feed can legitimately surface a channel the list read has not
    /// caught up to yet, and pushing nothing would be worse than pushing a thin row the
    /// timeline immediately fills in from the store.
    private func channelRow(for channelID: String, fallback entry: ActivityEntry? = nil) -> ChannelListRow {
        if let cached = model.channels.first(where: { $0.id == channelID }) { return cached }
        return ChannelListRow(
            id: channelID,
            name: entry.map { $0.channelName.isEmpty ? nil : $0.channelName } ?? nil,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: entry?.latest.createdAt,
            lastMessageID: entry?.latest.id,
            lastMessageSnippet: entry?.latest.content,
            lastMessageAuthor: entry?.latest.authorName,
            lastMessageAuthorPubkey: entry?.latest.pubkey,
            // Load-bearing rather than cosmetic: ``BuzzKit/ChannelListRow/isDirectMessage``
            // answers from it, so omitting it opens a direct message titled as a channel and
            // then corrects itself a frame later.
            channelType: (entry?.isDirectMessage ?? false) ? "dm" : nil
        )
    }

    /// The mark on the heading — the tab's own glyph, so the bar and the bar's screen say the
    /// same thing. The *unselected* cut: a heading is a label, not a state, and the solid one
    /// is what the tab bar says about where you are.
    ///
    /// Named here so a test can check it resolves to something.
    static let glyph = HomeTab.activity.icon(isSelected: false)

    /// Matched to ``ThreadsView``'s, so the two "what have I missed" lists in this app are
    /// laid out identically. Tighter vertically than that screen's 18, because a row here is
    /// one message rather than a thread's opener and its newest reply.
}
