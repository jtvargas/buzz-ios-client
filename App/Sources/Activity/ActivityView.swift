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
/// # Its own stack, and what that costs
///
/// This tab owns a `NavigationStack` separate from the sidebar's, so a conversation opened
/// from here backs out to *here* rather than to the channel list. That is the whole point of
/// an activity screen — you came to clear a list and you want to return to it — but it means
/// the app-wide values ``ChannelListView`` injects into *its* stack do not reach this one.
///
/// Only one of them is actually needed, and it is cheap: ``RelativeTimeTicker``, so the "7m"
/// on a row ages while the screen is open. This screen deliberately does **not** stand up a
/// second ``EntityDirectoryModel`` for names — the feed read resolves author names and
/// avatars in SQL and hands the channel's name over with each row, and a direct message is
/// titled by the person who wrote to you, who by construction is the only other person in
/// it. A second directory observation over the same tables to re-derive what the read
/// already knows would be a real cost for no visible difference.
///
/// If a third tab ever needs these, the answer is to hoist the resolvers above the
/// `TabView` in ``RootView``, not to build a third copy here.
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
    @State private var path: [ConversationRoute] = []
    /// The thread open on top, if any. Held here rather than inside a child for the same
    /// reason it is hoisted in the sidebar — the stack has to see every push that takes the
    /// tab bar down.
    @State private var openedThread: ThreadRoute?

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        _model = State(initialValue: ActivityModel(store: store, selfPubkey: selfPubkey))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .conversationTitle(mark: .symbol(Self.symbol), title: HomeTab.activity.title)
                // The same pull the sidebar and the Threads screen offer. This screen
                // summarises every channel, so a stale one misleads here exactly as much.
                .refreshable { await engine.refresh() }
                .navigationDestination(for: ConversationRoute.self) { route in
                    ChannelTimelineView(
                        channel: route.channel,
                        store: store,
                        engine: engine,
                        drafts: environment.drafts,
                        uploader: { environment.mediaUploader },
                        selfPubkey: selfPubkey,
                        knownPeer: route.knownPeer,
                        focusingComposer: route.focusesComposer
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
                        landingOn: route.anchor,
                        focusingComposer: route.focusesComposer
                    )
                }
        }
        // The same rule the sidebar's stack applies, through the same function: a reading
        // surface with a composer gets the full height, a list keeps the bar.
        .toolbar(
            ChannelListTabBar.visibility(conversations: path, openedThread: openedThread),
            for: .tabBar
        )
        // Injected on the stack rather than inside it, because a value attached below
        // `navigationDestination` never reaches the pushed view — the trap
        // ``ChannelListView`` documents at length.
        .environment(\.relativeTimeTicker, ticker)
        .task { await model.run() }
        .task { await ticker.run() }
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.entries(matching: filter)
        VStack(spacing: 0) {
            ActivityFilterRail(selection: $filter, unreadCount: model.unreadCount)
            List {
                ForEach(rows) { entry in
                    ActivityRow(entry: entry) { open(entry) }
                        .listRowInsets(Self.rowInsets)
                        // No rule between rows — the space separates them, the same call
                        // ``ThreadsView`` makes. A hairline under every row turns a list of
                        // summaries into a form.
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState(isFiltered: filter != .all, isEmpty: rows.isEmpty) }
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
                ContentUnavailableView(
                    "Nothing under \(filter.title)",
                    systemImage: Self.symbol,
                    description: Text("Other activity may be waiting under the chips above.")
                )
            } else {
                ContentUnavailableView(
                    "You're all caught up",
                    systemImage: "checkmark.circle",
                    description: Text("Mentions, replies and agent updates land here.")
                )
            }
        }
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
            openedThread = ThreadRoute(
                root: rootID,
                channel: channelID,
                anchor: entry.isUnread ? .latestReply : .opener
            )
        } else {
            path = ConversationRoute(channel: conversationRow(for: entry)).pushed(onto: path)
        }
    }

    /// The channel a row opens, built from what the feed already read back.
    ///
    /// ``ConversationRoute`` needs a ``BuzzKit/ChannelListRow`` and this screen does not
    /// hold the sidebar's list of them, so it builds the row from the feed's own columns —
    /// the same fallback ``ChannelListView/conversationRow(for:)`` uses for a channel it has
    /// not cached. The timeline re-reads everything it needs from the store on arrival, so
    /// the route only has to carry enough to name the destination correctly for the frame
    /// before that read lands.
    ///
    /// `channelType` is the one field here that is load-bearing rather than cosmetic: it is
    /// what ``BuzzKit/ChannelListRow/isDirectMessage`` answers from, so omitting it would
    /// open a direct message titled as though it were a channel and then correct itself a
    /// frame later. The unread counts are deliberately left at zero — the timeline does not
    /// read them off the route, and a stale count carried in from a list is worse than none.
    private func conversationRow(for entry: ActivityEntry) -> ChannelListRow {
        ChannelListRow(
            id: entry.channelID ?? "",
            name: entry.channelName.isEmpty ? nil : entry.channelName,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: entry.latest.createdAt,
            lastMessageID: entry.latest.id,
            lastMessageSnippet: entry.latest.content,
            lastMessageAuthor: entry.latest.authorName,
            lastMessageAuthorPubkey: entry.latest.pubkey,
            channelType: entry.isDirectMessage ? "dm" : nil
        )
    }

    /// The mark on the heading — the tab's own symbol, so the bar and the bar's screen say
    /// the same thing. Named here so a test can check the system actually has it.
    static let symbol = "bell"

    /// Matched to ``ThreadsView``'s, so the two "what have I missed" lists in this app are
    /// laid out identically. Tighter vertically than that screen's 18, because a row here is
    /// one message rather than a thread's opener and its newest reply.
    private static let rowInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
}
