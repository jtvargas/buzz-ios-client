import SwiftUI

/// How a conversation is recognised at a glance: the peer's face for a direct message,
/// a `#` tile for a channel, a lock for a private one, and how many people are in it for
/// a group direct message.
///
/// Extracted from ``ChannelRowView`` when the Drafts screen needed the same mark. A
/// conversation should be the same shape wherever it is listed, and two copies of a
/// rounded tile with a symbol in it is exactly the kind of thing that drifts one corner
/// radius at a time.
///
/// It draws the mark and nothing around it. The sidebar's presence dot stays with the
/// sidebar, as an overlay on this — presence is a fact about a person that only that
/// list reports.
struct ConversationMark: View {
    let conversation: ConversationIdentity
    let size: CGFloat
    /// The glyph's colour. The sidebar draws an unread channel's `#` at full strength and
    /// a read one quietly; the Drafts screen draws every mark at full strength, because
    /// there is no read state on that screen for a quiet mark to mean.
    var glyphTint: Color = .secondary
    /// Replaces the channel glyph. The Drafts screen passes a thread's own mark here, so a
    /// draft in a thread is distinguishable from a draft in the channel around it before
    /// the title is read.
    ///
    /// Ignored for a direct message of either size. A face names the person and a count
    /// names how many of them there are, both of which are more use than a symbol — and a
    /// thread in a DM is still a conversation with those same people.
    var symbol: String?

    var body: some View {
        switch conversation.kind {
        case .channel:
            tile {
                Image(systemName: symbol ?? (conversation.isPrivate ? "lock.fill" : "number"))
                    .font(.hiveSymbol(.subheadline, weight: .semibold))
                    .foregroundStyle(glyphTint)
            }
        case .group:
            // How many people are in it, where a one-to-one draws a face. A lock here
            // would say only "private", which every direct message is; the number is the
            // one thing about a group DM that a face cannot stand in for, and it is what
            // tells two of them apart before their names are read.
            tile {
                Text(Self.countText(conversation.memberCount))
                    .font(.hive(.subheadline, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(glyphTint)
            }
        case .direct, .agent:
            AvatarView(
                url: conversation.picture,
                seed: conversation.avatarSeed,
                monogram: conversation.initials,
                size: size
            )
        }
    }

    /// The rounded square both symbol marks are drawn on, so a `#` and a count cannot
    /// drift a corner radius apart.
    private func tile(@ViewBuilder _ content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: AvatarShape.roundedSquare.cornerRadius(for: size))
            .fill(Color.secondary.opacity(Self.tileOpacity))
            .frame(width: size, height: size)
            .overlay(content: content)
            .accessibilityHidden(true)
    }

    /// The roster size as it fits on a 30-point tile. The relay caps a DM at nine people
    /// (kind 41010 takes eight `p` tags and merges you in), so the second digit is for a
    /// group somebody later added to rather than one this app can create.
    static func countText(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private static let tileOpacity: CGFloat = 0.12
}
