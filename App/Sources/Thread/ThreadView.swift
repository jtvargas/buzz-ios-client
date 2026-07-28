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
    /// Pops back to the conversation this thread hangs off — the heading's own action, and
    /// the same pop the back button and the edge swipe perform, so there is one way out
    /// rather than three that could diverge.
    @Environment(\.dismiss) private var dismiss
    @State private var model: ThreadModel
    /// The same workspace roster the channel timeline reads, so a reply's presence dot
    /// and the profile sheet this view presents agree with the row that pushed it.
    @State private var presence: PresenceModel
    /// Whose profile is open, if anyone's — set by a tap on a reply's avatar or name.
    @State private var profilePeer: ProfilePeer?
    /// This device's per-thread read marks. Absent on a surface reached without them (the
    /// conversation fixture), where nothing is recorded.
    @Environment(\.threadReadMarks) private var threadReads
    private let channelID: String

    /// The mark on a thread's heading. `text.append` rather than a bubble or an arrow: it is
    /// the symbol for adding a line to something already written, which is what a thread is.
    /// Named here rather than at the call site so the test that it is a symbol the system
    /// actually has can reach it — a missing name renders as nothing at all, silently.
    static let threadSymbol = "text.append"

    /// Where this thread rests when it opens. A thread reached from a message in its own
    /// channel opens at the newest reply — the reader has the opener in front of them
    /// already. One reached from the Threads screen's row opens at the opener instead,
    /// because that row's tap is the question "what is this about".
    private let landing: ThreadLanding

    /// The production initialiser: the engine is all three of the collaborators below.
    init(
        root: String,
        channel: String,
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        landingOn landing: ThreadLanding = .latestReply
    ) {
        self.init(
            root: root,
            channel: channel,
            store: store,
            sender: engine,
            opener: engine,
            presence: engine.presenceStore,
            selfPubkey: selfPubkey,
            landingOn: landing
        )
    }

    /// The same view, with its collaborators named rather than taken from a `SyncEngine`.
    ///
    /// ``ThreadModel`` was always written against `MessageSending` and `ThreadOpening`; only
    /// this view's initialiser reached for the concrete engine, and a `SyncEngine` cannot be
    /// built without a relay socket. That made the scroll surface unreachable from a UI test,
    /// so the thirteen shapes that found the `#49`/`#50`/`#52` defects lived outside the repo
    /// and gated nothing — they rendered a *copy* of this screen, which is free to drift from
    /// it.
    ///
    /// This initialiser exists so a test drives **this** view. It adds no behaviour: the
    /// production path above delegates straight to it.
    init(
        root: String,
        channel: String,
        store: BuzzEventStore,
        sender: any MessageSending,
        opener: any ThreadOpening,
        presence: PresenceStore,
        selfPubkey: String?,
        landingOn landing: ThreadLanding = .latestReply
    ) {
        channelID = channel
        self.landing = landing
        _model = State(initialValue: ThreadModel(
            root: root,
            channel: channel,
            store: store,
            sender: sender,
            opener: opener,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presence))
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
            jumpTarget: model.jumpTarget,
            contentRevision: model.contentRevision,
            newestID: model.items.newestMessageID,
            onLeavingScreen: releaseComposer
        ) {
            list
        } bar: {
            ThreadComposerView(model: model)
        } accessory: {
            accessory
        }
        .overlay { emptyState }
        // The tab bar is hidden for a thread, for the same reason it is hidden for a
        // channel: a thread is a reading surface with a composer, and the bar would be a
        // second bottom inset under it. Declared by the view that owns the stack rather than
        // here — see ``ChannelListView/hidesTabBar``, which also explains why this view
        // keeping a `.hidden` of its own would not have been a harmless belt-and-braces: a
        // stack-level `.visible` beats it, so the two have to agree, so only one of them may
        // speak.
        .conversationTitle(
            mark: .symbol(Self.threadSymbol),
            title: "Thread",
            subtitle: .text(context),
            actionHint: "Double tap to return to the conversation",
            action: { dismiss() }
        )
        .profileSheet(peer: $profilePeer, presence: presence)
        // After the first render, so the scaffold's `onChange(of: jumpToken)` is installed
        // and the bump is a transition it sees — see ``ThreadModel/landOnOpener()``.
        .task { if landing == .opener { model.landOnOpener() } }
        .task { await model.run() }
        .task { await presence.run() }
        // Mark-on-view, the same discipline the channel's read state follows — and the
        // *rendered* newest row for the same reason: a reply held behind a frozen tail has
        // not been seen, so it must still count as new. Being here rather than in the model
        // is deliberate: this marker never leaves the device, so it is view state, not
        // something the thread publishes. Replying is covered without a second path — a sent
        // reply is a new newest row.
        .onChange(of: model.rows.last?.createdAt, initial: true) { _, newest in
            guard let newest else { return }
            threadReads?.mark(model.root, seenUpTo: newest)
        }
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
            // The channel's control, reading the thread's own jump state — see the
            // note on ``ChannelTimelineView``'s accessory for why the count is read
            // inside that view and not here.
            ConversationJumpControls(
                state: model.jump,
                onJumpToNew: { model.jumpToNewMessages() }
            )
            MentionSuggestionsView(
                document: $model.mentionDraft,
                autocomplete: model.mentionAutocomplete
            )
        }
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
    ///
    /// The heading names the way out and takes it: the second line already says which
    /// conversation this thread hangs off, so tapping it goes there. That it duplicates the
    /// back button beside it is the point — it is the larger target, and it is the one a
    /// reader's eye is already on.
    private var context: String {
        conversation.isDirect ? conversation.title : "#\(conversation.title)"
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
