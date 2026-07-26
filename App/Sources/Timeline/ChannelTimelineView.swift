import BuzzKit
import SwiftUI

/// A channel's timeline: newest at the bottom, older pages loaded at the top by
/// keyset cursor, day separators between local days, and a floating composer with the
/// "who is typing" strip above it. Messages carry reaction chips and a long-press menu
/// (react, copy, and retry/delete on own pending/failed rows); a threaded message
/// opens its thread. Reads are live from the store; presence and typing are live from
/// the engine's ``PresenceStore``; the composer sends and signals typing through it.
///
/// The list, the bar, and the keyboard/safe-area arithmetic all belong to
/// ``ConversationScaffold`` — this view supplies the three slots and nothing else, so
/// a thread and a DM inherit the same behaviour for free.
struct ChannelTimelineView: View {
    @State private var model: ChannelTimelineModel
    @State private var presence: PresenceModel
    @State private var typing: ChannelTypingModel
    @State private var openedThread: ThreadRoute?
    @State private var showsChannelDetails = false
    @Environment(\.entityNames) private var names
    private let channel: ChannelListRow
    private let title: String
    private let channelID: String
    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    /// Reserved for the top-of-history sentinel. Constant, and present whenever an
    /// older page may exist: a spinner that appears and disappears is itself a content
    /// height change at the top of a bottom-anchored list, which is one visible jump
    /// per page loaded.
    private static let topSentinelHeight: CGFloat = 44

    init(channel: ChannelListRow, store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.channel = channel
        title = (channel.name?.isEmpty == false) ? channel.name! : channel.id
        channelID = channel.id
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        let presenceStore = engine.presenceStore
        _model = State(initialValue: ChannelTimelineModel(
            channel: channel.id,
            store: store,
            sender: engine,
            typing: engine,
            readStateMarking: engine,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presenceStore))
        _typing = State(initialValue: ChannelTypingModel(
            channel: channel.id,
            store: presenceStore,
            selfPubkey: selfPubkey
        ))
    }

    var body: some View {
        ConversationScaffold(
            // A hand-written binding rather than `$model.isAtBottom`: a binding
            // projected through `State` of an observable class writes the reference
            // back into `State` on every set, which would invalidate this whole view
            // on each scroll threshold crossing.
            isAtBottom: Binding(get: { model.isAtBottom }, set: { model.isAtBottom = $0 }),
            jumpToken: model.jumpToken,
            onReachedTop: loadOlderPage
        ) {
            list
        } bar: {
            // One bottom bar, not two insets: stacked safe-area insets place the
            // last-applied one closest to the screen edge, which would put the typing
            // strip *below* the composer.
            VStack(spacing: 4) {
                TypingIndicatorView(model: typing, nameFor: authorName)
                ComposerView(model: model)
            }
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { titleItem }
        .sheet(isPresented: $showsChannelDetails) {
            ChannelDetailsView(
                channel: channel,
                store: store,
                presenceStore: engine.presenceStore
            )
        }
        .navigationDestination(item: $openedThread) { route in
            ThreadView(
                root: route.root,
                channel: route.channel,
                title: route.title,
                store: store,
                engine: engine,
                selfPubkey: selfPubkey
            )
        }
        .task { await model.run() }
        .task { await presence.run() }
    }

    // MARK: - List

    private var list: some View {
        LazyVStack(spacing: 0) {
            topSentinel
            // Day separators are items, not row headers, so the channel, a thread, and
            // a DM cannot each grow their own copy of the grouping rule. Grouped once
            // per rows change in the model; this pass is a read.
            ForEach(model.items) { item in
                switch item {
                case let .day(marker):
                    DaySeparatorView(date: marker.date)
                case let .message(row):
                    messageRow(row)
                }
            }
        }
        .padding(.vertical, 8)
        .dismissesSuggestionsOnScroll(model.mentionAutocomplete)
    }

    /// The fixed slot at the top of history: always ``topSentinelHeight`` tall while
    /// an older page may exist, with only the spinner's opacity tracking the load.
    @ViewBuilder
    private var topSentinel: some View {
        if model.hasMoreOlder {
            ProgressView()
                .frame(height: Self.topSentinelHeight)
                .opacity(model.isLoadingOlder ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: model.isLoadingOlder)
                .accessibilityHidden(true)
        }
    }

    private func messageRow(_ row: TimelineRow) -> some View {
        TimelineRowView(
            row: row,
            isAuthorOnline: presence.isOnline(row.pubkey),
            reactions: model.reactions(for: row.id),
            mentions: model.mentions(for: row.id),
            selfPubkey: selfPubkey,
            isOwn: model.isOwn(row),
            onRetry: { model.retry($0) },
            onReact: { model.react($0, on: row.id) },
            onToggleReaction: { model.toggleReaction($0, on: row.id) },
            onDelete: { model.delete($0) },
            onOpenThread: row.isDeleted ? nil : { open(thread: row) }
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    /// What floats over the list just above the composer: the held-back arrivals
    /// affordance, and the mention suggestion panel.
    private var accessory: some View {
        // A local `Bindable` rather than `$model`, for the same reason the `isAtBottom`
        // binding is hand-written above.
        @Bindable var model = model
        return VStack(spacing: 8) {
            if model.heldBackCount > 0 {
                NewMessagesPill(count: model.heldBackCount) {
                    model.jumpToLatest()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            MentionSuggestionsView(
                document: $model.mentionDraft,
                autocomplete: model.mentionAutocomplete
            )
        }
        // Scoped to the pill's presence, never to the list's content: an ambient
        // animation here would animate row insertion in a bottom-anchored list.
        .animation(.smooth(duration: 0.2), value: model.heldBackCount > 0)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded, model.rows.isEmpty {
            ContentUnavailableView(
                "No messages yet",
                systemImage: "text.bubble",
                description: Text("Say hello below.")
            )
        }
    }

    private var titleItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                showsChannelDetails = true
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Channel details for \(title)")
        }
    }

    /// The scaffold's "the top of history is near" report. It arrives as a level
    /// rather than an edge and can fire several times across one page load, which the
    /// model's own guard absorbs.
    private func loadOlderPage() {
        Task { await model.loadOlder() }
    }

    /// Opens the thread a row belongs to: its own id when it is the opener, its
    /// root when it is a (broadcast) reply.
    private func open(thread row: TimelineRow) {
        let root = row.rootID ?? row.id
        openedThread = ThreadRoute(root: root, channel: channelID, title: title)
    }

    /// A typer's name, through the injected directory — the same answer the sidebar,
    /// a message row, and a mention give. It replaces a scan of the loaded rows, which
    /// could only name someone who had already spoken in the page on screen.
    private func authorName(_ pubkey: String) -> String {
        names.name(for: pubkey)
    }
}

/// A pushed thread: its root id, the channel it lives in, and the title to show.
struct ThreadRoute: Hashable, Identifiable {
    let root: String
    let channel: String
    let title: String

    var id: String { root }
}
