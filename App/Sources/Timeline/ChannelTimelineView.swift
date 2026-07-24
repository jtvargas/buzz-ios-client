import BuzzKit
import SwiftUI

/// A channel's timeline: newest at the bottom, older pages loaded at the top by
/// keyset cursor, with the composer pinned below. Reads are live from the store;
/// the composer sends through the engine.
struct ChannelTimelineView: View {
    @State private var model: ChannelTimelineModel
    private let title: String

    init(channel: ChannelListRow, store: BuzzEventStore, engine: SyncEngine) {
        title = (channel.name?.isEmpty == false) ? channel.name! : channel.id
        _model = State(initialValue: ChannelTimelineModel(channel: channel.id, store: store, sender: engine))
    }

    /// The deterministic-testing / preview seam: inject any ``MessageSending``.
    init(model: ChannelTimelineModel, title: String) {
        _model = State(initialValue: model)
        self.title = title
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            ComposerView(model: model)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.run() }
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
                    TimelineRowView(row: row) { model.retry($0) }
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
}
