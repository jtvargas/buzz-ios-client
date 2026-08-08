import BuzzKit
import SwiftUI

struct SearchMessageRow: View {
    let hit: SearchMessageResult
    let names: EntityNames
    let onOpen: () -> Void

    var body: some View {
        SearchResultButton(action: onOpen) {
            AvatarView(
                url: hit.authorPicture.flatMap(URL.init(string:)) ?? names.picture(for: hit.pubkey),
                seed: hit.pubkey,
                monogram: hit.authorName.map(EntityNames.initials(from:)) ?? names.initials(for: hit.pubkey),
                size: 36
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hit.authorName ?? names.name(for: hit.pubkey))
                        .font(.hive(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    Text(names.conversation(for: hit.channelID).title)
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    MessageTimestampView(
                        date: Date(timeIntervalSince1970: TimeInterval(hit.createdAt)),
                        font: .hive(.caption2)
                    )
                }
                // Search ranges are offsets into the raw message. RichText changes offsets
                // while parsing markdown, so a result snippet deliberately styles that raw
                // value instead of pretending the ranges map onto a rendered block tree.
                SearchHighlightedText(text: hit.content, ranges: hit.matchRanges)
                    .font(.hive(.subheadline))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHint("Opens the conversation")
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
        .buttonStyle(.hivePress)
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
