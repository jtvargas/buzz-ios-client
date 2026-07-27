import BuzzKit
import SwiftUI

/// Recent thread activity across every channel: where the conversation is, who is in it,
/// and what was asked.
///
/// # What one row says, and what it deliberately does not
///
/// Where (`#channel`), who (`Jonathan, Jarvis, and 3 others`), and the opener itself, drawn
/// by the same ``TimelineRowView`` the channel and the thread draw it with — so a message
/// looks the same wherever it is read, and the replies strip under it is the real one, with
/// the real faces and the real count.
///
/// It does **not** draw the newest reply. That was here first and it was most of what made
/// the screen hard to read: two messages, two attributions and two timestamps per row, three
/// rows to a screen. A summary answers "what is this about"; reading the answer is what
/// opening the thread is for.
///
/// # The two ways in, and why a row needs both
///
/// "What is this about" is answered by the opener, so the row's own tap lands there.
/// "What did I miss" is answered by the newest reply, so **Reply** lands there instead, with
/// the composer ready. Making the row do only one of those forces everyone who wanted the
/// other to arrive in the wrong place and scroll.
struct ThreadsView: View {
    @Environment(\.entityNames) private var names
    /// This device's per-thread read marks. A thread already read here is no longer new,
    /// even though the channel's shared frontier has not moved.
    @Environment(\.threadReadMarks) private var threadReads
    @State private var model: ThreadsModel
    /// The thread this screen pushed, and where it should land when it opens.
    @State private var openedThread: ThreadRoute?
    /// Whose profile is open, if anyone's — set by pressing a mention inside a summary.
    @State private var profilePeer: ProfilePeer?
    /// The workspace roster, so the profile sheet this screen presents shows presence
    /// like the one a message row presents.
    @State private var presence: PresenceModel

    private let store: BuzzEventStore
    private let sender: any MessageSending
    private let opener: any ThreadOpening
    private let presenceStore: PresenceStore
    private let selfPubkey: String?

    /// The production initialiser: the engine is every collaborator below.
    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.init(
            store: store,
            sender: engine,
            opener: engine,
            presence: engine.presenceStore,
            selfPubkey: selfPubkey
        )
    }

    /// The same screen with its collaborators named, so a test can drive it without a
    /// relay socket — the seam ``ChannelTimelineView`` and ``ThreadView`` grew in #53.
    init(
        store: BuzzEventStore,
        sender: any MessageSending,
        opener: any ThreadOpening,
        presence: PresenceStore,
        selfPubkey: String?
    ) {
        self.store = store
        self.sender = sender
        self.opener = opener
        presenceStore = presence
        self.selfPubkey = selfPubkey
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
                    selfPubkey: selfPubkey,
                    names: names,
                    isUnseen: isUnseen(activity),
                    onOpen: { open(activity, at: .opener) },
                    onReply: { open(activity, at: .latestReply) },
                    onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
                )
                .listRowInsets(Self.rowInsets)
                // No rule between rows. The separation is the space: a hairline every 200pt
                // through a list of summaries reads as a form, and JT asked for the rows to
                // stand further apart, which a line between them works against.
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Threads")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyState }
        // The same modifier the timeline and a thread use, so pressing a mention here
        // presents the sheet those surfaces present rather than a second one.
        .profileSheet(peer: $profilePeer, presence: presence)
        .navigationDestination(item: $openedThread) { route in
            ThreadView(
                root: route.root,
                channel: route.channel,
                store: store,
                sender: sender,
                opener: opener,
                presence: presenceStore,
                selfPubkey: selfPubkey,
                landingOn: route.anchor
            )
        }
        .task { await model.run() }
        .task { await presence.run() }
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

    private func open(_ activity: ThreadActivity, at anchor: ThreadLanding) {
        openedThread = ThreadRoute(
            root: activity.rootID,
            channel: activity.channelID,
            anchor: anchor
        )
    }

    /// Whether this thread still holds something for the reader: replies past the channel's
    /// frontier that they have not already read here, on this device.
    private func isUnseen(_ activity: ThreadActivity) -> Bool {
        guard activity.hasNewReplies else { return false }
        guard let threadReads else { return true }
        return threadReads.hasUnseen(activity.rootID, latestReplyByOthersAt: activity.latestReplyByOthersAt)
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
    private static let rowInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
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

// MARK: - Row

/// One thread: where it is, who is in it, and the message that started it.
private struct ThreadActivityRow: View {
    let activity: ThreadActivity
    let channelTitle: String
    /// Everyone in the thread, the opener's author first.
    let people: [String]
    let openerMentions: [MentionRef]
    let selfPubkey: String?
    let names: EntityNames
    /// Whether this thread holds replies the reader has not seen.
    let isUnseen: Bool
    let onOpen: () -> Void
    let onReply: () -> Void
    let onOpenProfile: (String) -> Void

    @Environment(\.openConversation) private var openConversation
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // The real message row — the same one the channel and the thread draw, so the
            // opener reads identically in all three places. Its own tap, and the replies
            // strip it draws under itself, open the thread at that opener.
            TimelineRowView(
                row: ThreadSummary.summarised(activity.opener),
                mentions: openerMentions,
                replyParticipants: repliers,
                selfPubkey: selfPubkey,
                onRetry: { _ in },
                onOpenThread: onOpen,
                onOpenProfile: onOpenProfile,
                contentLineLimit: Self.openerLineLimit
            )
        }
        // Every interactive range of a summarised message is a link run — the only run of
        // a `Text` a reader can press. Without this they reach the system, which cannot
        // open a `hive-entity:` URL, so a tinted mention would look pressable and do
        // nothing. Routed exactly as ``TimelineRowView`` routes it, so the same pill does
        // the same thing on both surfaces.
        .environment(\.openURL, OpenURLAction { url in
            switch RichTextRoute(url: url) {
            case let .profile(pubkey):
                onOpenProfile(pubkey)
            case let .conversation(channelID):
                openConversation?(channelID)
            case let .external(url):
                openURL(url)
            case .none:
                openURL(url)
            }
            return .handled
        })
        .accessibilityElement(children: .contain)
    }

    /// Where this thread is, who is in it, and the way to its newest reply.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(channelTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let participants = ThreadParticipantSummary.text(names: peopleNames) {
                    Text(participants)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if isUnseen {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(
                        activity.newReplyCount == 1 ? "1 new reply" : "\(activity.newReplyCount) new replies"
                    )
            }
            Button("Reply", action: onReply)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityHint("Opens the thread at its newest reply")
        }
    }

    /// The people in the thread, as this reader sees them named.
    private var peopleNames: [String] {
        people.map { names.name(for: $0) }
    }

    /// The faces on the replies strip: the repliers, which is what that strip means
    /// everywhere else — the opener's own face is already on the message above it.
    private var repliers: [String] {
        Array(people.dropFirst().prefix(MessageRowMetrics.replyPreviewAvatars))
    }

    /// Enough of the opener to know what the thread is about. The 2,000-character cap
    /// (``ThreadSummary/summarised(_:)``) bounds what is parsed; this bounds what is drawn.
    private static let openerLineLimit = 6
}
