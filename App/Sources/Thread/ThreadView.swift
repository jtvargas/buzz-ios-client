import BuzzKit
import SwiftUI

/// A thread: its opener, a divider, then every reply oldest-first, each with its
/// reaction chips and long-press menu, and a reply composer pinned below. Reads are
/// live from the store; opening fetches the thread's replies once so it fills even
/// before live fan-out catches up.
struct ThreadView: View {
    @State private var model: ThreadModel
    private let title: String

    init(root: String, channel: String, title: String, store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.title = title
        _model = State(initialValue: ThreadModel(
            root: root,
            channel: channel,
            store: store,
            sender: engine,
            opener: engine,
            selfPubkey: selfPubkey
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            ThreadComposerView(model: model)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.run() }
    }

    private var messages: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.rows) { row in
                    // One view per element keeps the lazy stack's sizing stable as
                    // replies stream in, so the bottom anchor never fights a changing
                    // per-element view count.
                    VStack(spacing: 0) {
                        TimelineRowView(
                            row: row,
                            reactions: model.reactions(for: row.id),
                            mentions: model.mentions(for: row.id),
                            selfPubkey: model.selfPubkey,
                            isOwn: model.isOwn(row),
                            onRetry: { model.retry($0) },
                            onReact: { model.react($0, on: row.id) },
                            onToggleReaction: { model.toggleReaction($0, on: row.id) },
                            onDelete: { model.delete($0) }
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 4)

                        // Set the opener apart from its replies.
                        if row.id == model.root {
                            Divider().padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.hasLoaded, model.rows.isEmpty {
                ContentUnavailableView(
                    "Thread unavailable",
                    systemImage: "text.bubble",
                    description: Text("This thread couldn't be loaded.")
                )
            }
        }
    }
}

/// The reply composer: a Liquid Glass capsule field and a prominent send button, the
/// same treatment as the channel composer. Typing is signalled at the channel level,
/// so this composer does not publish its own typing.
private struct ThreadComposerView: View {
    @Bindable var model: ThreadModel
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($isFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)

                Button {
                    model.sendReply()
                    isFocused = false
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .padding(6)
                }
                .buttonStyle(.glassProminent)
                .clipShape(.circle)
                .disabled(!canSend)
                .accessibilityLabel("Send reply")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .animation(.default, value: canSend)
        .alert(
            "Reply not sent",
            isPresented: Binding(
                get: { model.sendError != nil },
                set: { if !$0 { model.sendError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.sendError = nil }
        } message: {
            Text(model.sendError ?? "")
        }
    }
}
