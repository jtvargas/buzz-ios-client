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
                    replyMentions: model.mentions(for: activity.latestReply.id),
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

// MARK: - Row

/// One thread: where it is, who is in it, the message that started it, and the last one
/// anybody has added to it.
private struct ThreadActivityRow: View {
    let activity: ThreadActivity
    let channelTitle: String
    /// Everyone in the thread, the opener's author first.
    let people: [String]
    let openerMentions: [MentionRef]
    /// The users the newest reply mentions. Resolved by the model in the same batched read
    /// as the opener's: a reply drawn with no refs renders its `@`-tokens as raw text, or as
    /// a pill that opens nobody.
    let replyMentions: [MentionRef]
    let selfPubkey: String?
    let names: EntityNames
    /// Whether this thread holds replies the reader has not seen.
    let isUnseen: Bool
    let onOpen: () -> Void
    let onReply: () -> Void
    let onOpenProfile: (String) -> Void

    @Environment(\.openConversation) private var openConversation
    @Environment(\.openURL) private var openURL

    /// The gutter the two messages indent their content by, so the **Reply** button under
    /// them can start on the same line their text does.
    ///
    /// A second `@ScaledMetric` over the same base constant rather than a value reached out
    /// of ``TimelineRowView``: the property wrapper resolves against the environment of the
    /// view that declares it, so there is nothing to read from another view even in
    /// principle — and both are declared `relativeTo: .subheadline` against
    /// ``MessageRowMetrics/avatarSize``, which is what keeps them equal at every text size.
    @ScaledMetric(relativeTo: .subheadline)
    private var avatarSize: CGFloat = MessageRowMetrics.avatarSize

    var body: some View {
        // One spacing for the whole stack, and it is the gap the channel and the thread put
        // between two messages. The two messages in this row are a conversation and should
        // sit apart by what a conversation sits apart by; giving the heading and the button
        // their own numbers would be three gaps to keep in step for no gain a reader can
        // name.
        VStack(alignment: .leading, spacing: MessageRowMetrics.betweenMessages) {
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
                contentLineLimit: Self.messageLineLimit
            )
            if let latestReply {
                // Deliberately the same row type, with no rule, no indent and no smaller
                // type: this is the conversation continuing, and #56's version — a caption
                // name over a snippet, hung off a vertical rule — was a second, quieter way
                // of drawing a message that a reader then had to learn. No replies strip
                // under it either; ``ThreadSummary/summarisedReply(_:)`` is what guarantees
                // that, and the strip that belongs to this thread is on the opener above.
                TimelineRowView(
                    row: latestReply,
                    mentions: replyMentions,
                    selfPubkey: selfPubkey,
                    onRetry: { _ in },
                    onOpenThread: onReply,
                    onOpenProfile: onOpenProfile,
                    contentLineLimit: Self.messageLineLimit
                )
            }
            replyButton
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

    /// Where this thread is, who is in it, and whether it holds anything unread.
    ///
    /// No control on it. **Reply** used to end this line, which put a filled capsule level
    /// with the channel name and gave the heading a trailing edge to fight the participant
    /// list for — the names truncated to make room for a button that acts on a message two
    /// rows below.
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
        }
    }

    /// The thread's newest reply, as a message this row can draw — or `nil` in the one shape
    /// where drawing it would be drawing the opener twice.
    ///
    /// # A thread with exactly one reply draws that reply
    ///
    /// It is the shape most threads are in, and it is the shape where suppressing the reply
    /// costs the most: the row would answer "what did I miss" with a face and the words
    /// `1 reply`. The replies strip above is not a second copy of this message — it is a
    /// count, a timestamp and up to four avatars, and it never contains a word anybody
    /// wrote. Reading the two together is "one person answered, and here is what they
    /// said", which is the whole of a short thread on one row and the best this screen
    /// ever reads.
    ///
    /// # The opener being its own newest reply
    ///
    /// ``BuzzKit/ThreadActivity`` promises `latestReply` is never absent but says nothing
    /// about it being a different message, and the read behind it would hand back the opener
    /// if the `thread` projection ever held a row whose `root_id` equalled its `event_id`.
    /// That needs an event carrying an `e` tag naming its own id, and an id is the SHA-256
    /// of the serialization those tags are in — a fixed point of the hash, which is to say
    /// it does not happen. The guard stays anyway because it is one comparison and the
    /// failure it prevents is the kind that gets filed as a rendering bug: the same
    /// sentence twice, under two avatars and two timestamps, with no hint that the data
    /// rather than the view is what is odd. A store seeded directly by a test or a fixture
    /// is not bound by SHA-256 either.
    private var latestReply: TimelineRow? {
        guard activity.latestReply.id != activity.opener.id else { return nil }
        return ThreadSummary.summarisedReply(activity.latestReply)
    }

    /// The way into the thread with the composer already up, under the message it answers.
    ///
    /// Indented onto the content column rather than left on the row's leading edge, because
    /// the leading edge is the avatar rail: a control starting there reads as a third
    /// participant in the conversation. On the text column it lines up with the replies
    /// strip under the opener, which is the other control in this row and the other way in.
    private var replyButton: some View {
        Button("Reply", action: onReply)
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityHint("Opens the thread at its newest reply")
            .padding(.leading, avatarSize + MessageRowMetrics.avatarGap)
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

    /// Enough of a message to know what it says. The 2,000-character cap
    /// (``ThreadSummary/summarised(_:)``) bounds what is parsed; this bounds what is drawn.
    ///
    /// One number for both messages, for the reason ``ThreadSummary/characterLimit`` is one
    /// number for both: they are the same kind of thing at the same size one above the
    /// other, and cutting the reply shorter than the opener would say the reply matters
    /// less — which is the opposite of what somebody opening this screen came for. Six lines
    /// each is a worst case no real conversation reaches; the common row is two short
    /// messages.
    private static let messageLineLimit = 6
}
