import SwiftUI

/// How a conversation is recognised at a glance: the peer's face for a direct message,
/// a `#` tile for a channel, a lock for a private one.
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
    /// The glyph's colour, for the one caller that varies it: the sidebar draws an unread
    /// channel's `#` at full strength. Everywhere else the mark is quiet.
    var glyphTint: Color = .secondary

    var body: some View {
        switch conversation.kind {
        case .channel:
            RoundedRectangle(cornerRadius: AvatarShape.roundedSquare.cornerRadius(for: size))
                .fill(Color.secondary.opacity(Self.tileOpacity))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: conversation.isPrivate ? "lock.fill" : "number")
                        .font(.hiveSymbol(.subheadline, weight: .semibold))
                        .foregroundStyle(glyphTint)
                }
                .accessibilityHidden(true)
        case .direct, .agent:
            AvatarView(
                url: conversation.picture,
                seed: conversation.avatarSeed,
                monogram: conversation.initials,
                size: size
            )
        }
    }

    private static let tileOpacity: CGFloat = 0.12
}
