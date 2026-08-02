import SwiftUI

/// The line between a thread's opener and its replies: how many replies there are, then the
/// way into everything else the opener can do.
///
/// Slack's thread pane, which is the reference: a rule under the opening message, the count
/// on its leading end, the overflow control on its trailing one. The rule is not new —
/// ``ThreadView`` has always drawn one here to set the opener apart — so this furnishes a
/// line that already exists rather than adding one.
///
/// # Why the count is handed in rather than counted here
///
/// The number is ``BuzzKit/TimelineRow/replyCount`` on the opener: the tally that same
/// message carried in the channel the reader tapped it from, composed by `TimelineQuery`
/// from this device's own replies and the relay's `kind:39005` summary of the thread. Two
/// things follow, and both are why the rows on screen are not counted instead — see
/// ``ThreadModel/replyCount``, where that is set out.
///
/// The one place the two disagree in front of the reader: an own reply still in the outbox,
/// or one that failed to send, is drawn as a row but is not in the tally. That is the
/// channel's answer to the same question, and it is the honest one — an undelivered reply is
/// not a reply anybody else has. One rule shared with the channel beats a second rule
/// written here.
struct ThreadOpenerDivider: View {
    /// How many replies the opener advertises. Zero draws no count at all — see
    /// ``replyLabel(for:)``.
    let replyCount: Int
    /// Opens the actions sheet on the opener. The same sheet a long press on any row here
    /// opens, which is why this presents rather than deciding anything for itself.
    let onOpenActions: () -> Void

    /// The count as it is written, or `nil` when there is nothing to write.
    ///
    /// A thread reached by "Reply in thread" has no replies yet — it is opened in order to
    /// make the first one — and `0 replies` under its opener would be furniture reporting
    /// its own emptiness. The reference draws nothing there either. The overflow control
    /// stays: it acts on the opener, which exists whether or not anybody has answered it.
    ///
    /// A separate function rather than an expression inside `body` because it is the only
    /// decision this view makes, and a decision inside a `body` is one no test can reach.
    static func replyLabel(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 reply" : "\(count) replies"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            bar
        }
        // The list's own inset, so the rule starts on the line the message above it starts
        // on — ``MessageRowMetrics/rowLeading`` names this rule as one of the four things
        // measured against it.
        .padding(.horizontal, MessageRowMetrics.rowLeading)
        // The inter-message spacing belongs to the enclosing stack, which would otherwise
        // leave the rule sitting against the opener it separates.
        .padding(.top, MessageRowMetrics.betweenMessages)
    }

    /// The line itself: the count on its leading end, the way into everything else on its
    /// trailing one.
    private var bar: some View {
        HStack(spacing: 8) {
            if let label = Self.replyLabel(for: replyCount) {
                Text(label)
                    // The weight ``RepliesButton`` gives the same words in a channel, in
                    // secondary rather than the tint: there the strip is a way into the
                    // thread, here the reader is already in it and there is nowhere for a
                    // tap to go. Tinted text a reader cannot press is the worse lie.
                    .font(.hive(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            actionsButton
        }
    }

    /// The overflow control: the sheet the channel and this screen already open on a long
    /// press, reached by something a reader can see.
    ///
    /// A bare glyph, not the glass capsule the same control wears on the Threads list. The
    /// two differ because their neighbours do — there it stands in a row of capsules, where
    /// a naked symbol reads as a label; here its only neighbour is a line of secondary text,
    /// and a capsule would be the loudest thing on the screen directly under the message it
    /// belongs to. The reference draws it bare for the same reason.
    ///
    /// 44pt square rather than the glyph's own size: the smallest target the HIG allows, and
    /// the height ``RepliesButton`` gives the equivalent strip in a channel, so the same line
    /// weighs the same on both surfaces. The glyph therefore sits half a target in from the
    /// rule's trailing end rather than flush with it — the target is what has to be
    /// comfortable, and a centred one is what every other icon button in the app does.
    ///
    /// Says what it opens rather than what it looks like: "More" alone is what an ellipsis
    /// already means to anyone who can see it and tells a listener nothing. The same two
    /// strings the Threads list uses, so one sheet reached from two screens is announced
    /// once.
    private var actionsButton: some View {
        Button(action: onOpenActions) {
            Image(systemName: "ellipsis")
                .font(.hiveSymbol(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .accessibilityLabel("More actions")
        .accessibilityHint("Reactions and actions for the message that opened this thread")
    }
}
