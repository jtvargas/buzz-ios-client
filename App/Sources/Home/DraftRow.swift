import BuzzKit
import SwiftUI

/// One unsent draft: where it would go, what it says, and when it was last touched.
///
/// The destination is the headline and the draft is the second line — the reader knows
/// what they wrote, and what they need from this screen is *which conversation it is
/// still sitting in*. Slack's Drafts list is built the same way round.
///
/// The leading mark is the sidebar's, from ``ConversationMark``: a face for a direct
/// message, how many people for a group one, a `#` or a lock for a channel. A draft is
/// about a conversation, and a conversation should be recognisable by the same thing
/// everywhere.
///
/// With one addition of this screen's own. A draft in a **channel's thread** draws the
/// thread's mark instead of the channel's, so the two are told apart before the title is
/// read — they are different destinations, and this list is the one place they sit next to
/// each other. A thread in a *direct message*, of either size, keeps the mark of the people
/// it is with: it is still a conversation with them, and a symbol would say less.
///
/// The glyph is drawn at full strength here, unlike the sidebar's, where a quiet mark
/// means read. There is no read state on this screen for quiet to mean.
struct DraftRow: View {
    let summary: ComposerDraftSummary
    /// How the conversation names itself, resolved through the shared directory so this
    /// screen cannot label a DM with a group id.
    let conversation: ConversationIdentity
    /// Whether the draft belongs to a thread rather than the conversation's own composer.
    var isThread: Bool { summary.rootID != nil }

    var body: some View {
        HStack(spacing: Self.betweenMarkAndText) {
            ConversationMark(
                conversation: conversation,
                size: Self.markSize,
                glyphTint: .primary,
                glyph: DraftRowMark.glyph(for: summary, in: conversation)
            )
            VStack(alignment: .leading, spacing: Self.betweenLines) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.hive(.headline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(Self.titleLines(for: conversation))
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    MessageTimestampView(date: date)
                }
                Text(preview)
                    .font(.hive(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The row spoken. The group DM's count is drawn rather than written, so `.combine`
    /// cannot reach it and it is named here.
    private var accessibilityLabel: String {
        var parts = [title]
        if let people = ChannelRowView.peopleDescription(conversation) { parts.append(people) }
        parts.append("draft: \(preview)")
        return parts.joined(separator: ", ")
    }

    private var title: String { DraftRowText.title(for: summary, in: conversation) }
    private var preview: String { DraftRowText.preview(of: summary.snippet) }

    /// A group direct message is titled by the people in it, and one line of a phone is
    /// about two names — so it gets a second, and the `…` falls at the end of that. Every
    /// other conversation has a name that was *chosen* to be a name and keeps its single
    /// line, which is what stops this list from growing rows of uneven height for titles
    /// that had nothing more to say.
    static func titleLines(for conversation: ConversationIdentity) -> Int {
        conversation.kind == .group ? 2 : 1
    }

    /// The stored millisecond stamp as a date — see ``ComposerDraftSummary/updatedAt``.
    private var date: Date {
        Date(timeIntervalSince1970: Double(summary.updatedAt) / 1000)
    }

    /// Matches the sidebar's own row mark, so a conversation is the same size here.
    private static let markSize: CGFloat = 36
    private static let betweenMarkAndText: CGFloat = 10
    private static let betweenLines: CGFloat = 2
}

/// Which mark a draft row draws over its channel tile, as a pure function.
///
/// `nil` leaves ``ConversationMark`` to draw what it draws everywhere else — the `#`, the
/// lock, or the peer's face.
enum DraftRowMark {
    static func glyph(for summary: ComposerDraftSummary, in conversation: ConversationIdentity) -> AppGlyph? {
        // A thread inside a channel is a different destination from the channel, and this
        // list is the one place the two sit next to each other. A thread inside a direct
        // message keeps the face: it is still a conversation with that person.
        guard summary.rootID != nil, conversation.kind == .channel else { return nil }
        return ThreadView.threadGlyph
    }
}

/// The two strings a draft row draws, as pure functions.
///
/// Out of the view because they are the rules a reader depends on — *which* conversation
/// this is, and enough of the draft to recognise it — and neither is something a test can
/// read back off a rendered row.
enum DraftRowText {
    /// `Thread in Design` for a reply, the conversation's own name otherwise. The one
    /// distinction a reader has to make at a glance, because the two land in different
    /// places.
    static func title(for summary: ComposerDraftSummary, in conversation: ConversationIdentity) -> String {
        summary.rootID == nil ? conversation.title : "Thread in \(conversation.title)"
    }

    /// The draft on one line.
    ///
    /// Newlines become spaces rather than the row truncating at the first one: a draft
    /// that opens with a blank line, or one written as a list, would otherwise preview as
    /// nothing at all. A draft that is *only* whitespace cannot be stored, so the fallback
    /// is a floor rather than a case anyone should reach.
    static func preview(of snippet: String) -> String {
        let flattened = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "Draft" : flattened
    }
}
