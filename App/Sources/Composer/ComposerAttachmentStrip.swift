import SwiftUI

/// The row of pictures above the text field, each with an X to take it off again.
///
/// # Sized in points, not scaled
///
/// The tile is a fixed 72pt square — the size the mobile client draws — and
/// deliberately not `@ScaledMetric`. Everything else in this composer scales with
/// Dynamic Type because it is type; this is a picture, and a picture does not get
/// easier to recognise for being larger. What does scale is the X's touch target,
/// through ``ComposerAttachmentStrip/removeTarget``, because that one is a thumb.
///
/// # Why the X is small and its target is not
///
/// A 24pt badge over a 72pt tile is the mobile client's proportion and it reads as
/// a badge rather than a button, which is right — it is a correction, not an
/// action. But 24pt is well under the 44pt floor, so the drawn badge and the
/// touchable area are separated: the glyph stays 24, and a transparent frame
/// around it takes the touch. The tile's own corner is where a thumb goes, so the
/// target is allowed to hang off the tile's edge.
struct ComposerAttachmentStrip: View {
    let attachments: [ComposerAttachment]
    let remove: (UUID) -> Void

    /// The drawn tile.
    private static let tile: CGFloat = 72
    /// The tile's corner, matching the message bubbles' own picture corners.
    private static let corner: CGFloat = 12
    /// The drawn X badge.
    private static let badge: CGFloat = 24
    /// What a thumb actually has to hit, never below the 44pt floor.
    @ScaledMetric(relativeTo: .body) private var removeTarget: CGFloat = 44

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    tile(for: attachment)
                }
            }
            // The tiles sit inside the shell's own padding; the extra leading inset
            // lines them up with the first glyph of the text field below.
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        // A picture wider than the bar is scrolled to, not squeezed: the row is as
        // tall as one tile and never more.
        .frame(height: Self.tile)
    }

    private func tile(for attachment: ComposerAttachment) -> some View {
        picture(for: attachment)
            .frame(width: Self.tile, height: Self.tile)
            .clipShape(.rect(cornerRadius: Self.corner))
            .overlay {
                // A hairline, so a photo whose edges are near-white still reads as a
                // tile rather than bleeding into the glass behind it.
                RoundedRectangle(cornerRadius: Self.corner)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) { removeButton(for: attachment) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(attachment.isUploading ? "Picture, uploading" : "Picture")
    }

    @ViewBuilder
    private func picture(for attachment: ComposerAttachment) -> some View {
        ZStack {
            // Behind the picture as well as instead of it: a decode that has not
            // landed yet and a tile whose picture is transparent both need something
            // under them.
            Rectangle().fill(.quaternary)
            if let preview = attachment.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            }
            if attachment.isUploading {
                // Over the picture rather than instead of it — the author picked a
                // specific photo and should see *that* one going up. The scrim is
                // what keeps the spinner legible over a bright picture.
                Rectangle().fill(.black.opacity(0.28))
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
    }

    private func removeButton(for attachment: ComposerAttachment) -> some View {
        Button {
            remove(attachment.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.hiveSymbol(.footnote, weight: .bold))
                // The glyph's own two layers: a dark cross on a light disc, so it
                // reads on a photo of any brightness without a shadow.
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black.opacity(0.75), .white)
                .frame(width: Self.badge, height: Self.badge)
                // Around the drawn badge, and *inward*: the target is what a thumb
                // needs and the badge is what the eye needs, but a target that hung
                // off the tile's edge would reach across the 6pt gap onto the next
                // picture, where it would remove the wrong one. Growing into the
                // tile costs nothing — a tile has no other touch of its own.
                .frame(width: removeTarget, height: removeTarget, alignment: .topTrailing)
                .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel("Remove picture")
    }
}
