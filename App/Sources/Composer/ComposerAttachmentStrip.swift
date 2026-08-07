import SwiftUI

/// The row of pictures above the text field, each with an X to take it off again, and a
/// dashed `+` on the end for another.
///
/// The add tile is where a second picture is actually reached from. The bar's `+` is two
/// taps away behind its card and, worse, reads as the way to start an attachment rather
/// than to continue one — so an author who had already picked one had no obvious way to
/// say "and this one". Putting the offer at the end of the row it extends is the mobile
/// client's answer and the one the owner asked for.
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
/// around it takes the touch. That frame grows *into* the tile rather than off its
/// edge — outward it would cross the 6pt gap onto the next picture and remove the
/// wrong one, and a tile has no touch of its own to compete with.
struct ComposerAttachmentStrip: View {
    let attachments: [ComposerAttachment]
    let remove: (UUID) -> Void
    /// Whether there is room for another picture. The add tile is dropped rather than
    /// disabled at the cap: a dashed outline is an invitation, and one that refuses the
    /// tap it invites is worse than the five pictures speaking for themselves.
    var canAddMore = false
    /// Opens the photo library for another picture. The strip does not present it —
    /// see ``MessageComposerView``, which owns the keyboard this has to be handed back to.
    var addMore: () -> Void = {}

    /// What ``ComposerAttachmentLayoutTests`` finds a tile by. A UI-testing bundle
    /// links none of this, so the string is the whole contract between the halves.
    static let tileIdentifier = "composerAttachment"
    /// The add tile's own name, deliberately *not* ``tileIdentifier``: the layout test
    /// measures a picture, and an empty outline answering to the same name would let it
    /// pass against a composer holding no pictures at all.
    static let addTileIdentifier = "composerAttachmentAdd"

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
                if canAddMore { addTile }
            }
            // Lined up with the first glyph of the text field below, not with the
            // shell's edge — see ``TokenTextView/textInset``.
            .padding(.horizontal, TokenTextView.textInset.width)
        }
        .scrollIndicators(.hidden)
        // A picture wider than the bar is scrolled to, not squeezed: the row is as
        // tall as one tile and never more.
        .frame(height: Self.tile)
    }

    /// The invitation on the end of the row: another picture goes here.
    ///
    /// A dashed outline rather than a filled tile, because it is the one thing in the row
    /// that is *not* a picture and the difference has to survive being glanced at next to
    /// five of them. Nothing inside it but the `+`, at the same weight as the bar's own,
    /// so the two read as the same offer made twice.
    ///
    /// The whole 72pt square is the target — well past the 44pt floor — so unlike the X
    /// badge there is no drawn-versus-touched split to keep in step here.
    private var addTile: some View {
        Button(action: addMore) {
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(
                    .tertiary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .frame(width: Self.tile, height: Self.tile)
                .overlay {
                    Image(systemName: "plus")
                        .font(.hiveSymbol(.title3, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.hivePress)
        .accessibilityLabel("Add another picture")
        .accessibilityIdentifier(Self.addTileIdentifier)
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
            .accessibilityLabel(accessibilityLabel(for: attachment))
            // Named so a UI test can measure the tile itself rather than infer it from
            // the X inside it — where the strip sits relative to the text field is the
            // whole assertion, and it is a rectangle, not a label.
            .accessibilityIdentifier(Self.tileIdentifier)
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
            if attachment.isPreparing {
                // One spinner, one meaning: this picture is being loaded and scrubbed
                // on-device. Relay upload progress belongs to the timeline row after send.
                // The scrim keeps the spinner legible over a bright preview.
                Rectangle().fill(.black.opacity(0.28))
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
    }

    private func accessibilityLabel(for attachment: ComposerAttachment) -> String {
        if attachment.isPreparing { return "Picture, preparing" }
        return "Picture"
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
        .buttonStyle(.hivePress)
        .accessibilityLabel("Remove picture")
    }
}
