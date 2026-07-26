import BuzzKit
import SwiftUI

/// The channel list: name, picture, and a preview of the newest message per
/// channel, live from the store, with the engine-state pill in the toolbar. Tapping
/// a channel pushes its timeline.
struct ChannelListView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: ChannelListModel
    @State private var presence: PresenceModel
    @State private var showAccount = false
    private let store: BuzzEventStore
    private let engine: SyncEngine

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        _model = State(initialValue: ChannelListModel(store: store, selfPubkey: selfPubkey))
        _presence = State(initialValue: PresenceModel(store: engine.presenceStore))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.channels.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(model.channels) { channel in
                                NavigationLink(value: channel) {
                                    ChannelRowView(
                                        channel: channel,
                                        mentions: model.mentions(for: channel),
                                        selfPubkey: environment.selfPubkeyHex,
                                        hasOnlineMember: model.hasOnlineMember(
                                            in: channel.id,
                                            online: presence.online
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(
                                    top: 4,
                                    leading: 12,
                                    bottom: 4,
                                    trailing: 12
                                ))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text("Your channels")
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Channels")
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
        .environment(\.channelNameMap, ChannelNameMap(channels: model.channels))
        .task { await model.run() }
        .task { await presence.run() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded {
            ContentUnavailableView(
                "No channels yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Channels appear here as they sync from the relay.")
            )
        } else {
            ProgressView()
        }
    }
}
