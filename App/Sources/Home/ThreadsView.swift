import BuzzKit
import SwiftUI

/// Recent thread activity across every channel: where the conversation is, who is in it,
/// what was asked, and the last thing said about it.
///
/// # What one row says
///
/// Where (`#channel`), who (`Jonathan, Jarvis, and 3 others`), and then the two messages
/// that bound the conversation — the opener and the thread's newest reply — each drawn by
/// the same ``TimelineRowView`` the channel and the thread draw them with, so a message
/// looks the same wherever it is read and the replies strip under the opener is the real
/// one, with the real faces and the real count.
///
/// The newest reply was taken *out* of this row in #56 and JT has asked for it back, so it
/// is worth writing down why the second attempt is not the first one again. What made the
/// original unreadable was not that there were two messages; it was that only one of them
/// was bounded. The opener went through ``ThreadSummary`` and the reply was handed to the
/// renderer whole, so a single long answer set the height of the row and the two messages
/// were drawn in two different shapes — a full row above, a name-and-snippet below — which
/// left nothing on screen agreeing about what a message looks like. Both messages now take
/// the same cut, the same line bound and the same row, and the height a row can reach is a
/// number stated in one place rather than whatever the last person typed.
///
/// # The two ways in, and why a row needs both
///
/// "What is this about" is answered by the opener, so the row's own tap lands there.
/// "What did I miss" is answered by the newest reply, so **Reply** lands there instead, with
/// the composer ready. Making the row do only one of those forces everyone who wanted the
/// other to arrive in the wrong place and scroll.
///
/// **Reply** sits under the newest reply rather than beside the heading. Beside the heading
/// it was level with the channel name and a row's worth of blank space away from anything it
/// acted on, which reads as an action on the *channel*; under the message it answers, it is
/// where the reader's eye already is when they have finished reading the thing they want to
/// reply to.
struct ThreadsView: View {
    @Environment(\.entityNames) private var names
    /// This device's per-thread read marks. A thread already read here is no longer new,
    /// even though the channel's shared frontier has not moved.
    @Environment(\.threadReadMarks) private var threadReads
    @State private var model: ThreadsModel
    /// The thread this screen pushed, and where it should land when it opens.
    ///
    /// Held by ``ChannelListView`` rather than here, because the view that owns the
    /// `NavigationStack` is the one that declares whether the tab bar is up, and it cannot
    /// declare that for a push it cannot see (``ChannelListView/hidesTabBar``). Only the
    /// The destination it opens is declared by that view too, now that the Drafts screen
    /// opens threads as well: two screens on one stack cannot each declare a destination
    /// for the same route type, and the stack that owns the push is the honest place for
    /// the one declaration. This screen still *sets* the route, so what it opens is
    /// unchanged.
    @Binding var openedThread: ThreadRoute?
    /// Whose profile is open, if anyone's — set by pressing a mention inside a summary.
    @State private var profilePeer: ProfilePeer?
    /// The workspace roster, so the profile sheet this screen presents shows presence
    /// like the one a message row presents.
    @State private var presence: PresenceModel

    private let store: BuzzEventStore
    private let refresher: any ConversationRefreshing
    /// Fills in the threads this device is behind on, once, on arrival. Optional for the
    /// reason given on ``ThreadPrefetching``.
    private let prefetcher: (any ThreadPrefetching)?
    private let presenceStore: PresenceStore
    private let selfPubkey: String?

    /// The production initialiser: the engine is every collaborator below.
    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        openedThread: Binding<ThreadRoute?>
    ) {
        self.init(
            store: store,
            refresher: engine,
            prefetcher: engine,
            presence: engine.presenceStore,
            selfPubkey: selfPubkey,
            openedThread: openedThread
        )
    }

    /// The same screen with its collaborators named, so a test can drive it without a
    /// relay socket — the seam ``ChannelTimelineView`` and ``ThreadView`` grew in #53.
    ///
    /// `openedThread` has no default on purpose. `.constant(nil)` would compile everywhere
    /// and silently swallow every push, which is the failure that is hardest to see: a test
    /// that taps a row and asserts a thread opened would fail with nothing wrong on screen.
    init(
        store: BuzzEventStore,
        refresher: any ConversationRefreshing,
        prefetcher: (any ThreadPrefetching)? = nil,
        presence: PresenceStore,
        selfPubkey: String?,
        openedThread: Binding<ThreadRoute?>
    ) {
        self.store = store
        self.refresher = refresher
        self.prefetcher = prefetcher
        presenceStore = presence
        self.selfPubkey = selfPubkey
        _openedThread = openedThread
        _model = State(initialValue: ThreadsModel(store: store, selfPubkey: selfPubkey))
        _presence = State(initialValue: PresenceModel(store: presence))
    }

    var body: some View {
        List {
            ForEach(model.threads) { activity in
                ThreadActivityRow(
                    activity: activity,
                    channelTitle: channelTitle(for: activity),
                    people: model.people(in: activity),
                    openerMentions: model.mentions(for: activity.opener.id),
                    replyMentions: model.mentions(for: activity.latestReply.id),
                    selfPubkey: selfPubkey,
                    names: names,
                    isUnseen: isUnseen(activity),
                    onOpen: { open(activity, at: .opener, focusesComposer: false) },
                    onOpenLatest: { open(activity, at: .latestReply, focusesComposer: false) },
                    onReply: { open(activity, at: .latestReply, focusesComposer: true) },
                    onMarkAsRead: { markAsRead(activity) },
                    onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
                )
                .listRowInsets(Self.rowInsets)
                // No rule between rows. The separation is the space: a hairline every 200pt
                // through a list of summaries reads as a form, and JT asked for the rows to
                // stand further apart, which a line between them works against.
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .hiveScreenGround()
        // The same pull the sidebar offers, for the same reason — see
        // ``ChannelListView/sidebar(names:)``. This screen summarises every channel's
        // threads, so a stale one is exactly as misleading here as there.
        .refreshable { await refresher.refresh() }
        .navigationTitle("Threads")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyState }
        // The same modifier the timeline and a thread use, so pressing a mention here
        // presents the sheet those surfaces present rather than a second one.
        .profileSheet(peer: $profilePeer, presence: presence)
        .task { await model.run() }
        .task { await presence.run() }
        // Every channel's threads, because that is what this screen lists. It runs on
        // arrival rather than on a sync, so a channel nobody looks at costs nothing — and
        // it is cheap to repeat, because a thread stops being a candidate once it has been
        // fetched. See ``BuzzKit/SyncEngine/prefetchThreads(in:)``.
        //
        // Its results arrive through `model.run()`'s observation, like a reply from the
        // relay would, so this awaits nothing and reads nothing back.
        .task { await prefetcher?.prefetchThreads(in: nil) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded, model.threads.isEmpty {
            ContentUnavailableView(
                "No threads yet",
                systemImage: ThreadView.threadSymbol,
                description: Text("Replies to a message appear here as a thread.")
            )
        }
    }

    private func open(
        _ activity: ThreadActivity,
        at anchor: ThreadLanding,
        focusesComposer: Bool
    ) {
        openedThread = ThreadRoute(
            root: activity.rootID,
            channel: activity.channelID,
            anchor: anchor,
            focusesComposer: focusesComposer
        )
    }

    /// Whether this thread still holds something for the reader: replies past the channel's
    /// frontier that they have not already read here, on this device.
    private func isUnseen(_ activity: ThreadActivity) -> Bool {
        guard activity.hasNewReplies else { return false }
        guard let threadReads else { return true }
        return threadReads.hasUnseen(activity.rootID, latestReplyByOthersAt: activity.latestReplyByOthersAt)
    }

    /// Clears a thread's unseen state in place — the same device-local mark ``ThreadView``
    /// writes on the open path (see ``ThreadReadMarks``), set straight to the thread's
    /// newest reply rather than waited on the reader scrolling down to it.
    ///
    /// Local and unpublished on purpose, exactly like the open path: NIP-RS keys read
    /// state by channel, so there is no per-thread frontier to publish this into without
    /// marking every other thread in the channel read along with it, on every device. See
    /// ``ThreadReadMarks`` for the full argument.
    private func markAsRead(_ activity: ThreadActivity) {
        threadReads?.mark(activity.rootID, seenUpTo: activity.latestReply.createdAt)
    }

    /// Where this thread lives, resolved through the shared directory — so a thread
    /// inside a direct message is labelled with the person rather than with whatever the
    /// relay called the group, exactly as ``ThreadView``'s own heading is.
    private func channelTitle(for activity: ThreadActivity) -> String {
        let conversation = names.conversation(for: activity.channelID)
        return conversation.isDirect ? conversation.title : "#\(conversation.title)"
    }

    /// Generous, and the reason the rule between rows is gone: with no hairline, the gap is
    /// the only thing saying where one thread ends and the next begins.
    ///
    /// Wider than the 14 that shipped in #56, because what the gap has to separate has
    /// changed. Then, two adjacent rows were two messages with a heading between them; now
    /// they are four, and 14pt between the last message of one thread and the heading of the
    /// next is *narrower* than the 12pt-plus-line-spacing between the two messages inside a
    /// single row — so the boundary between two conversations would be the least visible gap
    /// on the screen. Eighteen top and bottom makes it 36 between rows against 12 within one.
    private static let rowInsets = EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)
}

/// The Threads screen as a navigation value.
///
/// A type with no payload, and not a `Bool`, so the push goes through
/// `navigationDestination(item:)` like every other one in the app rather than through the
/// `isPresented` overload — which cannot say *which* screen it presents and so cannot sit
/// beside another destination on the same stack.
struct ThreadsRoute: Hashable, Identifiable {
    var id: String { "threads" }
}
