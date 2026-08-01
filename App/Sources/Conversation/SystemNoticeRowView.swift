import BuzzKit
import SwiftUI

/// A relay notice in the conversation, as a message-shaped row: *Echo*, the time, and
/// *was added by JT* underneath.
///
/// # Why it looks like a message
///
/// It used to be the opposite — a quiet grey sentence with no face, no name and no time,
/// on the theory that a notice must never be mistakable for something a person said.
/// The owner asked for the reference clients' shape instead (2026-08-01), and they are
/// both emphatic about it: Desktop's `SystemMessageRow.tsx` and mobile's
/// `system_rows.dart` each build the membership row out of the *same* avatar, header and
/// timestamp a message uses. The reason is that these events are about people, and a row
/// about a person that shows neither their face nor their name is the one thing a reader
/// scanning a channel cannot use.
///
/// What keeps it from reading as speech is the predicate: it is in the third person and
/// in secondary ink, so the row says *Echo — was added by JT* rather than putting words
/// in Echo's mouth.
///
/// # Whose face
///
/// ``SystemNotice/subject``'s, which is not always the actor: an arrival is about the
/// person who arrived, everything else about the person who acted. See that property —
/// the asymmetry is the reference clients' and it is load-bearing, not incidental.
///
/// # What it deliberately does not have
///
/// No reactions, no long-press actions, no profile tap. Desktop and mobile allow
/// reacting to a system message; that is a separate decision about whether relay
/// narration is a thing you can answer, and nothing here forecloses it.
struct SystemNoticeRowView: View {
    @Environment(\.entityNames) private var names
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize = MessageRowMetrics.avatarSize

    let notice: SystemNotice
    /// The others who arrived in the same breath, when a run of arrivals collapsed into
    /// this row. See ``ConversationGrouping/collapsingArrivals(_:)``.
    var alsoJoined: [String] = []
    /// When it happened. A notice sits among messages and has to be timestamped like
    /// one, so this comes from the marker rather than from the notice — the decoded
    /// body carries who and what, never when.
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: MessageRowMetrics.avatarGap) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                header
                Text(action)
                    .foregroundStyle(.secondary)
                    .lineSpacing(MessageRowMetrics.bodyLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, MessageRowMetrics.rowLeading)
        // One element reading one sentence, subject included. Without this the header
        // and the predicate are announced separately and "was added by JT" arrives as
        // its own utterance, about nobody.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence.plain)
    }

    /// The subject's face, at the same size and shape a message row gives an author, so
    /// the two line up down the gutter. Not a button: see the type doc.
    private var avatar: some View {
        AvatarView(
            url: names.picture(for: notice.subject),
            seed: notice.subject,
            monogram: names.initials(for: notice.subject),
            size: avatarSize
        )
    }

    /// Name then time, on the first text baseline — ``TimelineRowView/header``'s
    /// arrangement and for its reason, so a notice and the message above it put their
    /// attribution on the same line.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MessageRowMetrics.headerGap) {
            Text(sentence.title)
                .font(.hive(.subheadline, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            MessageTimestampView(date: date)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var sentence: SystemNoticeSentence {
        SystemNoticeSentence(notice, alsoJoined: alsoJoined, name: names.name(for:), selfPubkey: names.selfPubkey)
    }

    /// The predicate with the names inside it picked out. Built as one `AttributedString`
    /// rather than concatenated `Text`s so it wraps as a paragraph — a `Text` + `Text`
    /// chain wraps too, but each run becomes its own layout unit and a long name breaks
    /// the line before it instead of inside it.
    private var action: AttributedString {
        sentence.action.reduce(into: AttributedString()) { result, run in
            var piece = AttributedString(run.text)
            piece.font = run.isName ? .hive(.subheadline, weight: .semibold) : .hive(.subheadline)
            result.append(piece)
        }
    }
}
