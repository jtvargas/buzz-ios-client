import BuzzKit
import SwiftUI

/// A thread: its opener, a divider, then every reply oldest-first, each with its
/// reaction chips and long-press menu, and a reply composer pinned below. Reads are
/// live from the store; opening fetches the thread's replies once so it fills even
/// before live fan-out catches up.
struct ThreadView: View {
    @Environment(\.dismiss) private var dismiss
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    dismiss()
                } label: {
                    VStack(spacing: 0) {
                        Text("Thread")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("#\(title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to \(title)")
            }
        }
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
        .simultaneousGesture(TapGesture().onEnded {
            model.mentionAutocomplete.dismissComposer()
        })
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

    var body: some View {
        MessageComposerView(
            document: $model.mentionDraft,
            autocomplete: model.mentionAutocomplete,
            placeholder: "Reply",
            sendAccessibilityLabel: "Send reply",
            onSend: model.sendReply
        )
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
