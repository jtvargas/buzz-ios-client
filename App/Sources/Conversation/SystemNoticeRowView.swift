import BuzzKit
import SwiftUI

/// A relay notice in the conversation: *Sentry was added by You*.
///
/// # Why it is quiet, and how quiet
///
/// It is not a message and must not read as one. No avatar, no name header, no
/// timestamp, no reactions, no reply affordance — secondary text at `.footnote`, which
/// is the size of a timestamp and two steps under a message body. Slack's rule, and the
/// one JT asked for: present, scannable, and never mistakable for something a person
/// said.
///
/// The names inside it carry ``Font/hive(_:weight:)`` semibold *while the font is
/// built*, never `.fontWeight(.semibold)` over the surrounding font — weight here is a
/// value on Inter's `wght` axis, set as the face is resolved, and a trait layered on
/// afterwards is not that. See ``HiveTypography``.
///
/// # Where it starts
///
/// On the message *text* column, not the row's leading edge — one avatar gutter in.
/// A notice is a thing that happened inside the conversation, so it lines up with what
/// people said rather than with the day separators, which are headings over them.
struct SystemNoticeRowView: View {
    @Environment(\.entityNames) private var names
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize = MessageRowMetrics.avatarSize

    let notice: SystemNotice

    var body: some View {
        Text(attributed)
            .foregroundStyle(.secondary)
            .lineSpacing(MessageRowMetrics.bodyLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, MessageRowMetrics.rowLeading + avatarSize + MessageRowMetrics.avatarGap)
            .padding(.trailing, MessageRowMetrics.rowLeading)
            // One element reading one sentence. Without this the runs are announced
            // separately and "was added by" arrives as its own utterance.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence.plain)
    }

    private var sentence: SystemNoticeSentence {
        SystemNoticeSentence(notice, name: names.name(for:), selfPubkey: names.selfPubkey)
    }

    /// The sentence with its names picked out. Built as one `AttributedString` rather
    /// than concatenated `Text`s so it wraps as a paragraph — a `Text` + `Text` chain
    /// wraps too, but each run becomes its own layout unit and a long name breaks the
    /// line before it instead of inside it.
    private var attributed: AttributedString {
        sentence.runs.reduce(into: AttributedString()) { result, run in
            var piece = AttributedString(run.text)
            piece.font = run.isName ? .hive(.footnote, weight: .semibold) : .hive(.footnote)
            result.append(piece)
        }
    }
}
