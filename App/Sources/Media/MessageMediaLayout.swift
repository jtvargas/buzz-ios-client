import BuzzKit
import SwiftUI

/// Every number and every rule about how much room one attachment takes, as pure
/// arithmetic.
///
/// # Why this is a separate type and not a few constants in the view
///
/// The reservation *is* the feature. Rows live in a `LazyVStack` whose content metrics
/// are estimates, and a row that changes height once it is on screen moves everything
/// below it — which is the reader's place in the conversation. So the box an attachment
/// occupies has to be decided before its bytes arrive and never revisited, and a rule
/// that important is worth being able to assert on directly rather than by screenshotting
/// a view host.
///
/// Nothing here consults the loaded image. That is not an accident of the current
/// implementation; it is the invariant. If a future change makes the box depend on the
/// decoded bitmap, the conversation starts jumping again.
enum MessageMediaLayout {
    /// The widest an attachment is drawn inline, at any screen size.
    ///
    /// Upstream's `_messageMediaMaxInlineWidth`. Above this a picture stops being part of
    /// a message and starts being the message — and on an iPad, where a row is several
    /// hundred points wide, an uncapped attachment would run past the readable measure the
    /// text beside it keeps to.
    ///
    /// Upstream's rule is `min(screenWidth × 0.72, 320)`; the second half is taken and the
    /// first is not. Its 72% is measured against the *screen*, which on a phone leaves an
    /// attachment ~216 points wide inside a message column that is already ~300 — a
    /// picture inset from text that was not, for no reason the reader can see. Here the
    /// width offered is the message column's own, which the row has already inset past the
    /// avatar gutter, so a picture lines up with the words above it and the cap does the
    /// rest on a wide screen.
    static let maximumWidth: CGFloat = 320

    /// The tallest an attachment is drawn inline.
    ///
    /// Upstream's `_messageMediaMaxImageHeight`, taken unchanged. It is the number that
    /// stops a portrait photograph from being the whole conversation: on the shortest
    /// phone this app runs on it is under a third of the visible list, so the messages
    /// either side of a picture stay on screen with it.
    ///
    /// Deliberately **not** a `@ScaledMetric`. A picture is not text, and iOS's own
    /// messaging surfaces do not grow their attachments with Dynamic Type; scaling this
    /// would take the cap to ~480pt at the accessibility sizes, which is the exact
    /// outcome the cap exists to prevent. The text around the picture still scales without
    /// limit, and the full-screen viewer is one tap away for anyone who needs the picture
    /// larger — which is the affordance that actually answers "I cannot see it".
    static let maximumHeight: CGFloat = 240

    /// The shapes a declared aspect ratio is honoured within.
    ///
    /// Upstream's clamp, and the reason for it is the same here: `dim` is author-supplied,
    /// so a 30:1 banner or a 1:30 strip is describable and would reserve a 320×11 sliver
    /// or a 8×240 splinter. Outside this range the attachment is drawn in the clamped box
    /// *letterboxed rather than cropped* — see ``Box/isExact``.
    static let aspectRatioBounds: ClosedRange<CGFloat> = 0.2 ... 4

    /// The shape reserved for an image whose tag declared no usable `dim`.
    ///
    /// 4:3 is the commonest photograph, and at ``maximumWidth`` it comes out exactly
    /// ``maximumWidth``×``maximumHeight`` — so the unknown case reserves precisely the
    /// largest box any attachment can occupy, and no picture can ever want more room than
    /// the one whose size nobody declared.
    static let unknownImageAspectRatio: CGFloat = 4.0 / 3.0

    /// The shape reserved for a video with no declared `dim`. Upstream's fallback, and the
    /// shape a phone camera records in.
    static let unknownVideoAspectRatio: CGFloat = 16.0 / 9.0

    /// The corner radius of the frame an attachment is clipped to.
    static let cornerRadius: CGFloat = 10

    /// The box one attachment occupies: fixed at layout time, and never revisited.
    struct Box: Equatable {
        /// The reserved size, in points.
        let size: CGSize

        /// Whether ``size`` is the attachment's own shape.
        ///
        /// True only when the tag declared a ratio *and* that ratio was inside
        /// ``aspectRatioBounds``. It decides one thing: whether the picture fills the box
        /// or is letterboxed inside it.
        ///
        /// - An exact box is the picture's shape, so filling it crops nothing. `.fill`
        ///   rather than `.fit` because the two are the same answer here and only `.fill`
        ///   is immune to a half-point of rounding showing as a hairline stripe.
        /// - An inexact box is a *reservation*, not a shape: either nobody said what shape
        ///   the picture is, or they said something the cap could not honour. Filling it
        ///   would crop an unknown amount off an unknown edge — a face out of a portrait,
        ///   60% of a panorama — so the picture is fitted inside it instead, on the frame's
        ///   own fill. Letterboxing is the visible cost of an author who did not send
        ///   `dim`, and it is a much smaller cost than the conversation moving.
        let isExact: Bool

        /// How the picture is drawn inside ``size``.
        var contentMode: ContentMode { isExact ? .fill : .fit }
    }
}

// MARK: - The reservation

extension MessageMediaLayout {
    /// The box to reserve for `media` in a row `availableWidth` points wide.
    ///
    /// The width is taken up to ``maximumWidth`` and the height then derived from the
    /// shape; if that overflows ``maximumHeight`` the height is pinned and the width comes
    /// back down, so a portrait picture narrows rather than the conversation growing. That
    /// is upstream's `_imagePreviewSize`, with one deliberate difference: upstream reserves
    /// nothing at all when `dim` is missing and lets the loaded bytes size the widget,
    /// which is precisely the layout shift this client is not allowed to have.
    static func box(availableWidth: CGFloat, for media: MessageMedia) -> Box {
        box(availableWidth: availableWidth, aspectRatio: media.aspectRatio, kind: media.kind)
    }

    /// The reservation, decomposed so a test can drive the arithmetic without a model
    /// value for every case.
    static func box(availableWidth: CGFloat, aspectRatio: CGFloat?, kind: MessageMediaKind) -> Box {
        // A proposal can arrive unspecified, infinite, zero, or (from a probe) NaN. All of
        // them mean "you decide", and the largest inline box is the answer that keeps a
        // degenerate proposal from reserving a degenerate box.
        let offered = availableWidth.isFinite && availableWidth > 0 ? availableWidth : maximumWidth
        let declared = usable(aspectRatio)
        let ratio = declared.map { min(max($0, aspectRatioBounds.lowerBound), aspectRatioBounds.upperBound) }
            ?? fallbackAspectRatio(for: kind)

        var width = min(offered, maximumWidth)
        var height = width / ratio
        if height > maximumHeight {
            height = maximumHeight
            width = height * ratio
        }
        // A point of floor on each edge: a box that rounds to zero is a picture with no
        // hit target and a frame drawn as a line.
        return Box(
            size: CGSize(width: max(1, width), height: max(1, height)),
            isExact: isExact(aspectRatio: aspectRatio)
        )
    }

    /// The shape reserved when the tag declared nothing usable.
    static func fallbackAspectRatio(for kind: MessageMediaKind) -> CGFloat {
        switch kind {
        case .image: unknownImageAspectRatio
        case .video: unknownVideoAspectRatio
        }
    }

    /// Whether the box reserved for this ratio is the attachment's own shape — see
    /// ``Box/isExact``.
    ///
    /// Answerable without knowing the row's width, which is what lets a view pick its
    /// content mode outside the layout pass rather than threading the box back out of it.
    static func isExact(aspectRatio: CGFloat?) -> Bool {
        guard let ratio = usable(aspectRatio) else { return false }
        return aspectRatioBounds.contains(ratio)
    }

    /// How `media` is drawn inside its reservation.
    static func contentMode(for media: MessageMedia) -> ContentMode {
        isExact(aspectRatio: media.aspectRatio) ? .fill : .fit
    }

    /// A declared ratio that is a real, positive number, or `nil`.
    ///
    /// ``BuzzKit/MessageMedia/aspectRatio`` already refuses zero and negative extents; this
    /// is the second belt, because the value also arrives from
    /// ``box(availableWidth:aspectRatio:kind:)``'s own callers in tests and previews.
    private static func usable(_ aspectRatio: CGFloat?) -> CGFloat? {
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        return aspectRatio
    }
}

// MARK: - Decode sizes

extension MessageMediaLayout {
    /// The longest edge, in pixels, an inline attachment is decoded to.
    ///
    /// # Why this is a constant and not the box it is drawn in
    ///
    /// It is the largest edge any inline box can have (``maximumWidth``), which makes it
    /// independent of the row's width — and *that* is the point. Derived from the actual
    /// box instead, every attachment would carry a different cache key on an iPad than on
    /// a phone, a rotation would invalidate every decoded picture on screen at once, and a
    /// split-view resize would do it continuously. One key per attachment per screen
    /// scale means a rotation redraws bitmaps it already has.
    ///
    /// The cost of the overshoot is bounded and small: the only attachments decoded larger
    /// than they are drawn are the ones narrower than they are tall, and ImageIO caps the
    /// *longest* edge, so a portrait picture is decoded to at most 4:3's worth of extra
    /// rows. It never upscales, so a small source is unaffected either way.
    static func inlinePixelSize(displayScale: CGFloat) -> CGFloat {
        maximumWidth * validScale(displayScale)
    }

    /// The ceiling on what the full-screen viewer decodes to, in pixels on the longest
    /// edge.
    ///
    /// A bound rather than "whatever the source is": a 12000-pixel panorama would
    /// otherwise become a 500 MB bitmap on a device that will terminate for it. At this
    /// ceiling a 4:3 picture is ~16 MB decoded, which is one transient allocation for a
    /// surface showing exactly one thing.
    static let viewerMaximumPixelSize: CGFloat = 2400

    /// The longest edge, in pixels, the viewer decodes `media` to on a screen of `size`.
    ///
    /// Screen resolution is the target, because that is what a picture at rest is drawn
    /// at; zooming past that softens rather than re-decodes. Re-decoding per zoom step is
    /// what a tiled photo viewer does, and it is a great deal of machinery for a surface
    /// whose job is "let me look at this properly".
    ///
    /// The declared pixel size lowers the request where it can: asking ImageIO for 2400 px
    /// of a source that is 800 px wide gets 800 px back — it never upscales — but asking
    /// for exactly what is there keeps the cache key honest about what it holds.
    static func viewerPixelSize(screen: CGSize, displayScale: CGFloat, declared: CGSize?) -> CGFloat {
        let longestPoint = max(screen.width, screen.height)
        let screenPixels = longestPoint.isFinite && longestPoint > 0
            ? longestPoint * validScale(displayScale)
            : viewerMaximumPixelSize
        var target = min(screenPixels, viewerMaximumPixelSize)
        if let declared {
            let longestSource = max(declared.width, declared.height)
            if longestSource.isFinite, longestSource > 0 {
                target = min(target, longestSource)
            }
        }
        return max(1, target)
    }

    /// A display scale that cannot produce a nonsense pixel count. `@Environment` supplies
    /// a real one in the app; a preview or a test harness has been seen to supply zero.
    private static func validScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }
}

// MARK: - The reserving layout

/// Reserves ``MessageMediaLayout/box(availableWidth:aspectRatio:kind:)`` for its single
/// subview, whatever that subview would rather be.
///
/// # Why a `Layout` and not a `frame` or a `GeometryReader`
///
/// The box depends on the width the row offers, and every other way of learning that
/// width is worse here:
///
/// - `GeometryReader` takes all the space it is offered and reports the width *during*
///   layout, so the content it feeds is one pass behind — which in a `LazyVStack` is a row
///   that settles at a different height than it first claimed. That is the bug, not a
///   route to fixing it.
/// - `.aspectRatio(_:contentMode:)` under `.frame(maxWidth:maxHeight:)` gets to nearly the
///   right answer, but the interaction between an unspecified proposed height, an aspect
///   ratio and two maxima is not documented, and this codebase has already paid for
///   assuming a layout modifier does the obvious thing (see ``RichTextWidthCap``).
///
/// A `Layout` is the one construction that gets the proposal *before* it has to answer,
/// answers with arithmetic that is separately testable, and imposes the result on the
/// content rather than negotiating with it.
struct MessageMediaReservation: Layout {
    /// The attachment's declared shape, or `nil` when the tag carried none.
    let aspectRatio: CGFloat?
    /// Which fallback shape applies when there is no declared one.
    let kind: MessageMediaKind

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MessageMediaLayout.box(
            availableWidth: proposal.width ?? MessageMediaLayout.maximumWidth,
            aspectRatio: aspectRatio,
            kind: kind
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        // Proposed the bounds rather than the subview's own preference: the content of this
        // box is a picture, a placeholder, or a failure notice, and all three have to be
        // exactly the size that was reserved before anyone knew which of them it would be.
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}
