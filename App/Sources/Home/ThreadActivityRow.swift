import BuzzKit
import SwiftUI

/// One thread: where it is, who is in it, the message that started it, and the last one
/// anybody has added to it.
struct ThreadActivityRow: View {
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
    /// Clears ``isUnseen`` in place, without opening the thread.
    let onMarkAsRead: () -> Void
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
                    .font(.hive(.subheadline, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let participants = ThreadParticipantSummary.text(names: peopleNames) {
                    Text(participants)
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if isUnseen {
                Circle()
                    .fill(Color.hiveAccent)
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

    /// The way into the thread with the composer already up, under the message it answers —
    /// and, while the thread still holds something unseen, the solid button beside it that
    /// clears that state in place.
    ///
    /// Indented onto the content column rather than left on the row's leading edge, because
    /// the leading edge is the avatar rail: a control starting there reads as a third
    /// participant in the conversation. On the text column it lines up with the replies
    /// strip under the opener, which is the other control in this row and the other way in.
    private var replyButton: some View {
        HStack(spacing: 8) {
            Button("Reply", action: onReply)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityHint("Opens the thread at its newest reply")
            // Solid rather than outlined, the same pairing `.glass`/`.glassProminent`
            // draws everywhere else in the app: **Reply** is one of several ways in,
            // **Mark As Read** is the one action this row commits on the spot, and the
            // fill is what says so before either label is read.
            if isUnseen {
                Button("Mark As Read", action: onMarkAsRead)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .accessibilityHint("Marks this thread read without opening it")
            }
        }
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
