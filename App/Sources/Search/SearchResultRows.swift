import BuzzKit
import SwiftUI

struct SearchMessageRow: View {
    let hit: SearchMessageResult
    let names: EntityNames
    /// Whether this row's tap has not yet produced a screen. The one piece of state the row
    /// does not own: only the stack knows when the destination is actually up.
    var isOpening = false
    let onOpen: () -> Void

    /// Where the message lives, said the way the reader would say it.
    private var place: SearchResultPlace {
        SearchResultPlace(
            conversation: names.conversation(for: hit.channelID),
            isThreadReply: hit.threadRootID != nil
        )
    }

    var body: some View {
        SearchResultButton(action: onOpen) {
            AvatarView(
                url: hit.authorPicture.flatMap(URL.init(string:)) ?? names.picture(for: hit.pubkey),
                seed: hit.pubkey,
                monogram: hit.authorName.map(EntityNames.initials(from:)) ?? names.initials(for: hit.pubkey),
                size: 36
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hit.authorName ?? names.name(for: hit.pubkey))
                        .font(.hive(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    // The separator is drawn rather than punctuating the name, so a long name
                    // truncates on its own and does not take the time with it.
                    Text(verbatim: "·")
                        .font(.hive(.caption2))
                        .foregroundStyle(.tertiary)
                    MessageTimestampView(
                        date: Date(timeIntervalSince1970: TimeInterval(hit.createdAt)),
                        font: .hive(.caption2)
                    )
                    Spacer(minLength: 4)
                    if isOpening {
                        // In the row rather than over it: the reader is looking at the thing
                        // they just pressed, and a spinner anywhere else is a second place to
                        // look. It replaces nothing, so no text reflows when it appears.
                        ProgressView()
                            .controlSize(.mini)
                            .transition(.opacity)
                    }
                }
                place
                // Search ranges are offsets into the raw message. RichText changes offsets
                // while parsing markdown, so a result snippet deliberately styles that raw
                // value instead of pretending the ranges map onto a rendered block tree.
                SearchHighlightedText(text: hit.content, ranges: hit.matchRanges)
                    .font(.hive(.subheadline))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth(duration: 0.15), value: isOpening)
        .accessibilityHint(place.accessibilityHint)
    }
}

/// The line under a result's byline: what the hit is, and which conversation it is in.
///
/// # Why the conversation is a chip and the rest is a sentence
///
/// Because they are answers to different questions and a reader scanning results is only
/// asking one of them at a time. The sentence is the same on nearly every row, so it reads as
/// furniture and disappears; the name is what differs, and a chip is what makes it findable
/// without reading the sentence again on every row. It is the shape the owner's reference
/// used, and the reason it works.
struct SearchResultPlace: View {
    let conversation: ConversationIdentity
    /// Whether this hit is a reply the channel's own page does not show — see
    /// ``BuzzKit/MessageSearchHit/threadRootID``. It changes where a tap goes, so it has to
    /// change what the row promises.
    let isThreadReply: Bool

    /// The words before the chip.
    private var lead: String {
        isThreadReply ? "Reply in a thread in" : "Message in"
    }

    /// What the chip says. Channels wear their `#`; a direct message is a person's name and
    /// would be wrong with one.
    private var name: String {
        conversation.isDirect ? conversation.title : "#\(conversation.title)"
    }

    /// One sentence for a screen reader, which cannot see that the chip is part of the line.
    var accessibilityHint: String { "\(lead) \(name). Opens the message." }

    var body: some View {
        HStack(spacing: 5) {
            Text(lead)
                .font(.hive(.caption))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.hive(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: .rect(cornerRadius: 6, style: .continuous))
        }
        // The chip carries the name; a screen reader gets it from the row's hint instead, in
        // a sentence rather than as two fragments.
        .accessibilityHidden(true)
    }
}

private struct SearchResultButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: MessageRowMetrics.avatarGap) {
                label()
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        // `.row`, not the default `.control`: this is a full-width list row, and the two
        // emphases differ in where the shrink sits relative to the wash — a control's wash
        // shrinks with it, a row's stays put. See ``PressFeedbackButtonStyle/Emphasis``.
        .buttonStyle(.hivePress(.row))
        .accessibilityElement(children: .combine)
    }
}

private struct SearchHighlightedText: View {
    let text: String
    let ranges: [SearchMatchRange]

    var body: some View {
        Text(value)
    }

    private var value: AttributedString {
        var value = AttributedString(text)
        for match in ranges {
            let range = NSRange(location: match.location, length: match.length)
            guard let stringRange = Range(range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: value),
                  let upper = AttributedString.Index(stringRange.upperBound, within: value)
            else { continue }
            value[lower..<upper].foregroundColor = .accentColor
            value[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return value
    }
}
