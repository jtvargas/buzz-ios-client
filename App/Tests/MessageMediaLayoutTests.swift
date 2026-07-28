import BuzzKit
import CoreGraphics
@testable import Hive
import SwiftUI
import Testing
import UIKit

/// The reservation: how much room one attachment takes, and — the part that matters —
/// that the answer is decided without ever consulting the picture.
///
/// A row that settles at a different height once its bytes arrive displaces every row
/// below it in a `LazyVStack`, which is the reader's place in the conversation. Every
/// assertion here is that requirement, taken from a different angle.
@Suite("Message media layout")
struct MessageMediaLayoutTests {
    static let maxWidth = MessageMediaLayout.maximumWidth
    static let maxHeight = MessageMediaLayout.maximumHeight

    static func box(_ width: CGFloat, _ ratio: CGFloat?, _ kind: MessageMediaKind = .image) -> MessageMediaLayout.Box {
        MessageMediaLayout.box(availableWidth: width, aspectRatio: ratio, kind: kind)
    }

    /// Sizes are compared with a tolerance rather than for equality.
    ///
    /// The fallback shapes are `4/3` and `16/9`, neither of which is representable in
    /// binary, so a box derived by dividing by one lands a few units in the last place
    /// away from the round number it is meant to be. Asserting exact equality here would
    /// be asserting a property of IEEE 754 rather than a property of the layout — and a
    /// third of a nanometre of a point is not a layout shift.
    static func close(_ size: CGSize, _ width: CGFloat, _ height: CGFloat) -> Bool {
        abs(size.width - width) < 0.001 && abs(size.height - height) < 0.001
    }
}

// MARK: - A declared aspect ratio

extension MessageMediaLayoutTests {
    @Test("a declared shape is reserved exactly, up to the width cap")
    func honoursDeclaredShape() {
        // 800×400 in a 300-point column: the picture's own shape, no letterboxing.
        let fits = Self.box(300, 2)
        #expect(Self.close(fits.size, 300, 150))
        #expect(fits.isExact)
        #expect(fits.contentMode == .fill)

        // A column wider than the cap does not make the picture wider than the cap.
        let wide = Self.box(900, 2)
        #expect(Self.close(wide.size, Self.maxWidth, Self.maxWidth / 2))
    }

    @Test("a portrait picture narrows rather than the conversation growing")
    func capsHeightByNarrowing() {
        // 600×1200. At full width it would be 640 points tall — two thirds of a phone.
        let portrait = Self.box(Self.maxWidth, 0.5)
        #expect(Self.close(portrait.size, Self.maxHeight * 0.5, Self.maxHeight))
        #expect(portrait.isExact)

        // A square is the same rule at the boundary: the cap binds, the shape survives.
        let square = Self.box(Self.maxWidth, 1)
        #expect(Self.close(square.size, Self.maxHeight, Self.maxHeight))
    }

    @Test("no declared shape reserves any box larger than the cap allows")
    func neverExceedsTheCap() {
        // A sweep rather than a handful of cases: the cap is the promise that one picture
        // cannot take over the conversation, and it has to hold for every shape.
        for ratio in stride(from: 0.05, through: 20, by: 0.05) {
            for width in [1, 120, 300, Self.maxWidth, 900] as [CGFloat] {
                let box = Self.box(width, CGFloat(ratio))
                #expect(box.size.width <= Self.maxWidth)
                #expect(box.size.height <= Self.maxHeight)
                #expect(box.size.width > 0)
                #expect(box.size.height > 0)
            }
        }
    }
}

// MARK: - No declared aspect ratio

extension MessageMediaLayoutTests {
    @Test("an undeclared shape still reserves a stable box, and says it is not the shape")
    func reservesForAnUndeclaredShape() {
        let unknown = Self.box(Self.maxWidth, nil)
        // 4:3 at the width cap is exactly the largest box anything can occupy, so the
        // picture nobody described can never want more room than one that was.
        #expect(Self.close(unknown.size, Self.maxWidth, Self.maxHeight))
        // The box is a reservation, not a shape — so the picture is fitted inside it when
        // it arrives rather than cropped to fill it.
        #expect(unknown.isExact == false)
        #expect(unknown.contentMode == .fit)

        // Narrower column, same shape.
        #expect(Self.close(Self.box(240, nil).size, 240, 180))
    }

    @Test("a video with no dimensions reserves 16:9, not a photograph's shape")
    func videoFallsBackToItsOwnShape() {
        let video = Self.box(Self.maxWidth, nil, .video)
        #expect(Self.close(video.size, Self.maxWidth, Self.maxWidth * 9 / 16))
        #expect(video.isExact == false)
        // A declared shape is honoured for a video exactly as it is for a picture.
        #expect(Self.close(Self.box(Self.maxWidth, 1, .video).size, Self.maxHeight, Self.maxHeight))
    }

    @Test("a shape outside the clamp is drawn inside its box, never cropped to it")
    func clampsExtremeShapes() {
        // A 30:1 banner would reserve a 320×11 sliver. Clamped to 4:1 — and reported as
        // *not* the picture's shape, so it is letterboxed rather than having 60% of it
        // cropped away.
        let banner = Self.box(Self.maxWidth, 30)
        #expect(Self.close(banner.size, Self.maxWidth, Self.maxWidth / 4))
        #expect(banner.isExact == false)
        #expect(banner.contentMode == .fit)

        // And the same at the other end.
        let strip = Self.box(Self.maxWidth, 0.01)
        #expect(Self.close(strip.size, Self.maxHeight * 0.2, Self.maxHeight))
        #expect(strip.isExact == false)
    }

    @Test("a degenerate proposal reserves the largest box rather than a degenerate one")
    func survivesDegenerateProposals() {
        // A `Layout` is probed with zero, with infinity, and — from some hosts — with NaN.
        // All of them mean "you decide", and none of them may produce a box of nothing.
        for width in [0, -50, CGFloat.nan, .infinity, -.infinity] as [CGFloat] {
            let box = Self.box(width, 2)
            #expect(Self.close(box.size, Self.maxWidth, Self.maxWidth / 2))
        }
        // A ratio the model should already have refused, refused again here.
        #expect(Self.box(Self.maxWidth, 0).isExact == false)
        #expect(Self.close(Self.box(Self.maxWidth, .nan).size, Self.maxWidth, Self.maxHeight))
        #expect(Self.close(Self.box(Self.maxWidth, -2).size, Self.maxWidth, Self.maxHeight))
    }
}

// MARK: - The model's own answer

extension MessageMediaLayoutTests {
    @Test("the box is read from the imeta tag, and a tag with no dim is the unknown case")
    func readsTheAttachment() {
        let declared = MessageMedia(url: "https://x/a.png", kind: .image, pixelSize: CGSize(width: 1600, height: 900))
        #expect(Self.box(Self.maxWidth, declared.aspectRatio) ==
            MessageMediaLayout.box(availableWidth: Self.maxWidth, for: declared))
        #expect(MessageMediaLayout.contentMode(for: declared) == .fill)

        let bare = MessageMedia(url: "https://x/b.png", kind: .image)
        #expect(MessageMediaLayout.box(availableWidth: Self.maxWidth, for: bare).isExact == false)
        #expect(MessageMediaLayout.contentMode(for: bare) == .fit)

        // A zero extent is not a shape, and `MessageMedia` already resolves it to nil.
        let broken = MessageMedia(url: "https://x/c.png", kind: .image, pixelSize: CGSize(width: 100, height: 0))
        #expect(MessageMediaLayout.contentMode(for: broken) == .fit)
    }
}

// MARK: - Decode targets

extension MessageMediaLayoutTests {
    @Test("the inline decode target does not depend on the row's width")
    func inlineDecodeTargetIsStable() {
        // The whole point: one cache key per attachment per screen scale, so a rotation or
        // a split-view resize redraws bitmaps it already has instead of decoding again.
        #expect(MessageMediaLayout.inlinePixelSize(displayScale: 3) == Self.maxWidth * 3)
        #expect(MessageMediaLayout.inlinePixelSize(displayScale: 2) == Self.maxWidth * 2)
        // A host that reports no scale still asks for a real number of pixels.
        #expect(MessageMediaLayout.inlinePixelSize(displayScale: 0) == Self.maxWidth)
        #expect(MessageMediaLayout.inlinePixelSize(displayScale: .nan) == Self.maxWidth)
    }

    @Test("the viewer asks for screen resolution, bounded, and never more than the source has")
    func viewerDecodeTarget() {
        let phone = CGSize(width: 393, height: 852)
        // 852 points at 3× is 2556, past the ceiling that keeps one picture from being a
        // 30 MB allocation.
        #expect(MessageMediaLayout.viewerPixelSize(screen: phone, displayScale: 3, declared: nil)
            == MessageMediaLayout.viewerMaximumPixelSize)
        // At 2× it is under the ceiling and the screen decides.
        #expect(MessageMediaLayout.viewerPixelSize(screen: phone, displayScale: 2, declared: nil) == 1704)

        // A source smaller than the screen is asked for at its own size: ImageIO will not
        // upscale, so asking for more would only make the cache key claim more than it holds.
        let small = CGSize(width: 800, height: 600)
        #expect(MessageMediaLayout.viewerPixelSize(screen: phone, displayScale: 3, declared: small) == 800)
        // A source larger than the ceiling is still bounded by it.
        let huge = CGSize(width: 12000, height: 4000)
        #expect(MessageMediaLayout.viewerPixelSize(screen: phone, displayScale: 3, declared: huge)
            == MessageMediaLayout.viewerMaximumPixelSize)

        // Degenerate inputs from a host that has not laid out yet.
        #expect(MessageMediaLayout.viewerPixelSize(screen: .zero, displayScale: 3, declared: nil)
            == MessageMediaLayout.viewerMaximumPixelSize)
        #expect(MessageMediaLayout.viewerPixelSize(screen: phone, displayScale: 3, declared: .zero)
            == MessageMediaLayout.viewerMaximumPixelSize)
    }
}

// MARK: - The layout, hosted

extension MessageMediaLayoutTests {
    /// The arithmetic above is only worth having if the `Layout` actually imposes it, so
    /// this measures the real thing through a hosting controller.
    ///
    /// The assertion that *is* the feature is the last one: the same reservation, asked for
    /// twice with wildly different content inside it, measures the same. That is what
    /// "the row does not change height when the picture arrives" reduces to, because the
    /// loading placeholder, the failure notice and the picture are exactly that — different
    /// content in one box.
    @MainActor
    @Test("the layout reserves the computed box whatever is inside it")
    func hostedReservationIgnoresItsContent() {
        let proposal = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)

        func measure(_ content: some View, aspectRatio: CGFloat?) -> CGSize {
            let reservation = MessageMediaReservation(aspectRatio: aspectRatio, kind: .image) { content }
            return UIHostingController(rootView: reservation).sizeThatFits(in: proposal)
        }

        // A tiny leaf and one far larger than the box, which is the spread between an
        // unloaded placeholder and a decoded photograph.
        let placeholder = measure(Color.red.frame(width: 8, height: 8), aspectRatio: nil)
        let picture = measure(Color.red.frame(width: 4000, height: 4000), aspectRatio: nil)
        let expected = Self.box(300, nil).size

        #expect(abs(placeholder.width - expected.width) < 0.5)
        #expect(abs(placeholder.height - expected.height) < 0.5)
        #expect(placeholder == picture)

        // And the declared case measures its declared shape, not the content's.
        let declared = measure(Color.red.frame(width: 4000, height: 4000), aspectRatio: 2)
        #expect(abs(declared.height - 150) < 0.5)
    }
}
