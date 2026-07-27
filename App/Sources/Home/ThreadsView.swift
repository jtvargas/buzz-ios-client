import BuzzKit
import SwiftUI

/// Recent thread activity across every channel: what was asked, what was answered last,
/// and how much sits in between.
///
/// # The two ways in, and why a row needs both
///
/// A row is a summary of a conversation, and there are two different things someone
/// wants from one. "What is this about" is answered by the opener, so the row's own tap
/// lands there. "What did I miss" is answered by the newest reply, so **Reply** lands
/// there instead, with the composer ready. Making the row do only one of those forces
/// everyone who wanted the other to arrive in the wrong place and scroll.
struct ThreadsView: View {
    @Environment(\.entityNames) private var names
    @Environment(\.channelNameMap) private var channelNames
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
                    openerMentions: model.mentions(for: activity.opener.id),
                    replyMentions: model.mentions(for: activity.latestReply.id),
                    channelNames: channelNames,
                    selfPubkey: selfPubkey,
                    names: names,
                    onOpen: { open(activity, at: .opener) },
                    onReply: { open(activity, at: .latestReply) },
                    onOpenProfile: { profilePeer = ProfilePeer(pubkey: $0) }
                )
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.visible)
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

    /// Where this thread lives, resolved through the shared directory — so a thread
    /// inside a direct message is labelled with the person rather than with whatever the
    /// relay called the group, exactly as ``ThreadView``'s own heading is.
    private func channelTitle(for activity: ThreadActivity) -> String {
        let conversation = names.conversation(for: activity.channelID)
        return conversation.isDirect ? conversation.title : "#\(conversation.title)"
    }

    private static let rowInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
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

/// One thread: who asked, in which conversation, what they said, how much was said back,
/// and the last thing anyone said.
private struct ThreadActivityRow: View {
    let activity: ThreadActivity
    let channelTitle: String
    let openerMentions: [MentionRef]
    let replyMentions: [MentionRef]
    let channelNames: ChannelNameMap
    let selfPubkey: String?
    let names: EntityNames
    let onOpen: () -> Void
    let onReply: () -> Void
    let onOpenProfile: (String) -> Void

    @Environment(\.openConversation) private var openConversation
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // The row's own tap opens the thread at its opener, so the opener's text is
            // the button — not the whole row, which would swallow Reply's tap.
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    RichTextView(
                        text: ThreadSummary.opener(activity.opener.content),
                        resolver: resolver(for: openerMentions)
                    )
                    .lineLimit(Self.openerLineLimit)
                    if let more = ThreadSummary.moreReplies(activity) {
                        Text(more)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            latestReply
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

    /// Who opened the thread, where, and when it was last active. The time is the *last
    /// reply's*, not the opener's: this list is ordered by that, so any other number here
    /// would read as the order being wrong.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(names.name(for: activity.opener.pubkey))
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            Text(channelTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            MessageTimestampView(date: activity.latestReply.date, font: .caption2)
                .fixedSize()
            if activity.hasNewReplies {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(
                        activity.newReplyCount == 1 ? "1 new reply" : "\(activity.newReplyCount) new replies"
                    )
            }
        }
    }

    /// The newest reply, and the way into it.
    private var latestReply: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(names.name(for: activity.latestReply.pubkey))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                RichTextView(
                    text: activity.latestReply.content,
                    resolver: resolver(for: replyMentions),
                    mode: .snippet
                )
                .lineLimit(Self.replyLineLimit)
            }
            Spacer(minLength: 8)
            Button("Reply", action: onReply)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityHint("Opens the thread at its newest reply")
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            // The rule that says "this hangs off the message above" — the one piece of
            // chrome that keeps the reply from reading as a second, unrelated message.
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
                .accessibilityHidden(true)
        }
    }

    /// The shared aliasing, exactly as a timeline row builds it, so a profile-less
    /// mention resolves here and in the thread this row opens identically.
    private func resolver(for mentions: [MentionRef]) -> MessageMentionResolver {
        MessageMentionResolver(
            mentions: names.aliased(mentions),
            channels: channelNames,
            selfPubkey: selfPubkey
        )
    }

    /// Enough of the opener to know what the thread is about; the 2,000-character cap
    /// (``ThreadSummary/opener(_:)``) is what stops a long one costing a parse it will
    /// never show.
    private static let openerLineLimit = 6
    /// The newest reply is a hint, not the reply itself — reading it is what opening the
    /// thread is for.
    private static let replyLineLimit = 3
}
