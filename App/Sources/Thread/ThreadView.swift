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
    @Environment(\.entityNames) private var names
    @State private var model: ThreadModel
    /// The same workspace roster the channel timeline reads, so a reply's presence dot
    /// and the profile sheet this view presents agree with the row that pushed it.
    @State private var presence: PresenceModel
    /// Whose profile is open, if anyone's — set by a tap on a reply's avatar or name.
    @State private var profilePeer: ProfilePeer?
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
        _presence = State(initialValue: PresenceModel(store: engine.presenceStore))
    }

    var body: some View {
        // The thread is read here rather than in `init` (see `primeIfNeeded()`): a `body`
        // runs before layout, so the bottom anchor still resolves against real content,
        // while the view structs SwiftUI initialises and discards on every commit cost an
        // allocation instead of three blocking store reads on the main actor.
        model.primeIfNeeded()

        return ConversationScaffold(
            // Hand-written rather than `$model.isAtBottom`, which would write the
            // model reference back into `State` on every scroll threshold crossing.
            isAtBottom: Binding(get: { model.isAtBottom }, set: { model.isAtBottom = $0 }),
            jumpToken: model.jumpToken,
            onLeavingScreen: releaseComposer
        ) {
            list
        } header: {
            header
        } bar: {
            ThreadComposerView(model: model)
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        // Hidden for the same reason the channel hides it, and it matters more here: this is
        // the surface a reader arrives at *by* pushing, so the back affordance in the row has
        // to be the real one.
        .toolbar(.hidden, for: .navigationBar)
        .profileSheet(peer: $profilePeer, presence: presence)
        .task { await model.run() }
        .task { await presence.run() }
    }

    // MARK: - List

    private var list: some View {
        // The channel's rhythm, from the same constant, so a message does not change
        // size or spacing when a reader follows it into its thread.
        LazyVStack(spacing: MessageRowMetrics.betweenMessages) {
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
                isAuthorOnline: presence.isOnline(row.pubkey),
                reactions: model.reactions(for: row.id),
                mentions: model.mentions(for: row.id),
                selfPubkey: model.selfPubkey,
                isOwn: model.isOwn(row),
                onRetry: { model.retry($0) },
                onReact: { model.react($0, on: row.id) },
                onToggleReaction: { model.toggleReaction($0, on: row.id) },
                onDelete: { model.delete($0) },
                // No `onOpenThread`: a reply inside a thread has nowhere further to go,
                // which is also why no row here draws a reply preview.
                onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
            )
            // The shared constant rather than a bare `.padding(.horizontal)`, so a reply
            // starts on the same line as the header pill and the day separators above it.
            .padding(.horizontal, MessageRowMetrics.rowLeading)

            // Set the opener apart from its replies. Padded, because the inter-message
            // spacing now belongs to the enclosing stack and would otherwise leave the
            // rule sitting against the opener it separates.
            if row.id == model.root {
                Divider()
                    .padding(.horizontal, MessageRowMetrics.rowLeading)
                    .padding(.top, MessageRowMetrics.betweenMessages)
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

    /// The header: `Thread` over the conversation it hangs off, in the same row and the same
    /// glass pill the channel uses (§4).
    ///
    /// The pill is not a control. It used to dismiss on tap, which duplicated the back
    /// chevron with no affordance saying so — and §4's rule that a header only advertises an
    /// action when it has one cuts the same way for a hidden one. The chevron beside it is
    /// the way out, and now that the row draws it rather than the system bar it is the
    /// *only* way out other than the swipe.
    ///
    /// No glyph: `#` marks a channel, and this pill's own first line already says what it is.
    private var header: some View {
        ConversationHeaderRow {
            ConversationHeaderPill(title: "Thread", subtitle: context)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Thread in \(conversation.title)")
        }
    }

    /// The scaffold's "this surface is leaving the screen" report. A reply composer's
    /// keyboard must not outlive the thread it belongs to — nor be restored under the
    /// channel once this view is gone, which is what UIKit does if the responder is still
    /// held when the window detaches.
    private func releaseComposer() {
        model.mentionAutocomplete.dismissComposer()
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
