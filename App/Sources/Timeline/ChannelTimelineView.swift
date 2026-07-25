import BuzzKit
import SwiftUI

/// A channel's timeline: newest at the bottom, older pages loaded at the top by
/// keyset cursor, with a "who is typing" strip and the composer pinned below.
/// Messages carry reaction chips and a long-press menu (react, copy, and
/// retry/delete on own pending/failed rows); a threaded message opens its thread.
/// Reads are live from the store; presence and typing are live from the engine's
/// ``PresenceStore``; the composer sends and signals typing through the engine.
struct ChannelTimelineView: View {
    @State private var model: ChannelTimelineModel
    @State private var presence: PresenceModel
    @State private var typing: ChannelTypingModel
    @State private var openedThread: ThreadRoute?
    private let title: String
    private let channelID: String
    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    init(channel: ChannelListRow, store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
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
        VStack(spacing: 0) {
            messages
            TypingIndicatorView(model: typing, nameFor: authorName)
            ComposerView(model: model)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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

    private var messages: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.hasMoreOlder {
                    ProgressView()
                        .padding()
                        .task { await model.loadOlder() }
                }
                ForEach(model.rows) { row in
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
                        onOpenThread: row.hasThread ? { open(thread: row) } : nil
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.hasLoaded, model.rows.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "text.bubble",
                    description: Text("Say hello below.")
                )
            }
        }
    }

    /// Opens the thread a row belongs to: its own id when it is the opener, its
    /// root when it is a (broadcast) reply.
    private func open(thread row: TimelineRow) {
        let root = row.rootID ?? row.id
        openedThread = ThreadRoute(root: root, channel: channelID, title: title)
    }

    /// Resolves a typer's pubkey to a display name from a message they have sent in
    /// view, falling back to a short key. Typers are few, so the row scan is cheap.
    private func authorName(_ pubkey: String) -> String {
        if let row = model.rows.first(where: { $0.pubkey == pubkey }) {
            return row.displayName
        }
        return String(pubkey.prefix(8))
    }
}

/// A pushed thread: its root id, the channel it lives in, and the title to show.
struct ThreadRoute: Hashable, Identifiable {
    let root: String
    let channel: String
    let title: String

    var id: String { root }
}
