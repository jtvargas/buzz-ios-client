import SwiftUI

/// The full-screen viewer's header: who posted the picture, when, and where.
///
/// # Why it is a pill rather than a navigation bar
///
/// A photograph is judged against what surrounds it, which is why the viewer forces a
/// black background and a dark scheme. A bar is a horizontal band of chrome across the
/// top of that; a pill is a small object floating on it, and it leaves the picture the
/// whole width of the screen at the one moment the reader came here to look at it. It is
/// also the shape the owner specified from Slack's own viewer.
///
/// # Why it does not lead anywhere
///
/// Everything it names is somewhere the reader just came *from* — their own conversation,
/// one dismissal away. A tappable name here would be a second route to a profile sheet
/// presented over a modal, which is the presentation race ``MessageActionsSheet`` already
/// had to be restructured to avoid. The pill is a label, and reads as one to VoiceOver.
struct MessageMediaViewerHeader: View {
    let attribution: MessageMediaAttribution

    /// The face's point size, scaled against the name beside it so the two grow together.
    @ScaledMetric(relativeTo: .subheadline) private var faceSize: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                url: attribution.authorPictureURL,
                seed: attribution.authorSeed,
                monogram: attribution.authorInitials,
                size: faceSize,
                shape: .circle
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(attribution.authorName)
                        .font(.hive(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                    // The row's own arrangement: the time keeps its width and the name
                    // gives way, because a truncated hour says nothing while a truncated
                    // name still names somebody.
                    Text(attribution.timeLabel())
                        .font(.hive(.footnote))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                        .layoutPriority(1)
                }
                Text(attribution.placeLabel)
                    .font(.hive(.footnote))
                    .foregroundStyle(.white.opacity(0.75))
            }
            // Two lines at most, and the name and the place each hold one: a group DM's
            // title is a list of names that would otherwise wrap the pill down the screen.
            .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        // Glass and nothing under it. An opaque wash beneath the material was the first
        // build's answer to legibility over a light photograph, and it reads as a dark
        // plate with a sheen rather than as glass — which is not what was asked for. The
        // viewer forces a dark scheme, so `.regular` resolves to its dark variant whatever
        // the picture behind it is doing, and that is what keeps white text on it.
        //
        // `.interactive()` is the owner's ask, and it is honest here rather than
        // decorative: the pill is hit-testable — its own material takes the touch that
        // would otherwise reach the picture — so a finger landing on it gets the
        // material's response instead of nothing at all.
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attribution.accessibilityLabel)
        // Named for ``MediaViewerLayoutTests``, which asks where this landed relative to
        // the screen — a question the label cannot answer, since the label is a sentence
        // about a person and this is a question about a rectangle.
        .accessibilityIdentifier(MessageMediaViewerHeader.identifier)
    }

    /// The pill's accessibility identifier.
    static let identifier = "mediaViewerHeader"
}
