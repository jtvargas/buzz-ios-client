import BuzzKit
import SwiftUI

/// A channel's timeline: newest at the bottom, older pages loaded at the top by
/// keyset cursor, with a "who is typing" strip and the composer pinned below. Reads
/// are live from the store; presence and typing are live from the engine's
/// ``PresenceStore``; the composer sends and signals typing through the engine.
struct ChannelTimelineView: View {
    @State private var model: ChannelTimelineModel
    @State private var presence: PresenceModel
    @State private var typing: ChannelTypingModel
    private let title: String

    init(channel: ChannelListRow, store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        title = (channel.name?.isEmpty == false) ? channel.name! : channel.id
        let presenceStore = engine.presenceStore
        _model = State(initialValue: ChannelTimelineModel(
            channel: channel.id,
            store: store,
            sender: engine,
            typing: engine
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
                    TimelineRowView(row: row, isAuthorOnline: presence.isOnline(row.pubkey)) {
                        model.retry($0)
                    }
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

    /// Resolves a typer's pubkey to a display name from a message they have sent in
    /// view, falling back to a short key. Typers are few, so the row scan is cheap.
    private func authorName(_ pubkey: String) -> String {
        if let row = model.rows.first(where: { $0.pubkey == pubkey }) {
            return row.displayName
        }
        return String(pubkey.prefix(8))
    }
}
