import BuzzKit
import SwiftUI

/// A thread: its opener, a divider, then every reply oldest-first, each with its
/// reaction chips and long-press menu, and a reply composer floating below. Reads are
/// live from the store; opening fetches the thread's replies once so it fills even
/// before live fan-out catches up.
///
/// The same ``ConversationScaffold`` as the channel timeline, minus pagination — a
/// thread is loaded whole — so the keyboard, the safe area, and the floating bar
/// behave identically without a second copy of that arithmetic.
struct ThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.entityNames) private var names
    @State private var model: ThreadModel
    private let channelID: String

    init(root: String, channel: String, store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        channelID = channel
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
        ConversationScaffold(
            // Hand-written rather than `$model.isAtBottom`, which would write the
            // model reference back into `State` on every scroll threshold crossing.
            isAtBottom: Binding(get: { model.isAtBottom }, set: { model.isAtBottom = $0 }),
            jumpToken: model.jumpToken
        ) {
            list
        } bar: {
            ThreadComposerView(model: model)
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { titleItem }
        .task { await model.run() }
    }

    // MARK: - List

    private var list: some View {
        LazyVStack(spacing: 0) {
            // The same grouped items the channel renders, so a thread that spans days
            // separates them the same way; the model suppresses the separator that
            // would otherwise sit above the thread's own opener.
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

    private func messageRow(_ row: TimelineRow) -> some View {
        // One view per element: the lazy stack's per-element subview count stays
        // constant as replies stream in, so the bottom anchor never fights a row that
        // is sometimes one child and sometimes two.
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

    private var accessory: some View {
        // A local `Bindable` rather than `$model`: a binding projected through `State`
        // of an observable class writes the reference back into `State` on every set,
        // invalidating this whole view where only the composer needed to hear about it.
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
        .animation(.smooth(duration: 0.2), value: model.heldBackCount > 0)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded, model.rows.isEmpty {
            ContentUnavailableView(
                "Thread unavailable",
                systemImage: "text.bubble",
                description: Text("This thread couldn't be loaded.")
            )
        }
    }

    /// The conversation this thread hangs off, resolved through the shared directory
    /// rather than carried down from the pushing view — so a thread inside a DM is
    /// labelled with the person, not with the group the relay happens to have named.
    private var conversation: ConversationIdentity {
        names.conversation(for: channelID)
    }

    /// The line under "Thread": `#channel` for a channel, and a plain name for a direct
    /// message, where a `#` would be a category error.
    private var context: String {
        conversation.isDirect ? conversation.title : "#\(conversation.title)"
    }

    private var titleItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                dismiss()
            } label: {
                VStack(spacing: 0) {
                    Text("Thread")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(conversation.title)")
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
