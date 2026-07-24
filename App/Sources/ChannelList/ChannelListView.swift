import BuzzKit
import SwiftUI

/// The channel list: name, picture, and a preview of the newest message per
/// channel, live from the store, with the engine-state pill in the toolbar. Tapping
/// a channel pushes its timeline.
struct ChannelListView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: ChannelListModel
    private let store: BuzzEventStore
    private let engine: SyncEngine

    init(store: BuzzEventStore, engine: SyncEngine) {
        self.store = store
        self.engine = engine
        _model = State(initialValue: ChannelListModel(store: store))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.channels.isEmpty {
                    emptyState
                } else {
                    List(model.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Channels")
            .navigationDestination(for: ChannelListRow.self) { channel in
                ChannelTimelineView(channel: channel, store: store, engine: engine)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EngineStatePill(state: environment.engineState)
                }
            }
        }
        .task { await model.run() }
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
