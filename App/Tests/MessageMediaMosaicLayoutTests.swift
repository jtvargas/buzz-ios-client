import BuzzKit
import CoreGraphics
@testable import Hive
import SwiftUI
import Testing
import UIKit

/// The mosaic's own arithmetic: how many cells, what shape, and — the property that
/// matters, mirroring ``MessageMediaLayoutTests`` for the single-picture reservation —
/// that the answer never depends on what has loaded into any of them.
@Suite("Message media mosaic layout")
struct MessageMediaMosaicLayoutTests {
    static let width = MessageMediaMosaicLayout.maximumWidth
}

// MARK: - Frame counts and shapes

extension MessageMediaMosaicLayoutTests {
    @Test("zero or one picture is not a mosaic")
    func notAMosaicBelowTwo() {
        #expect(MessageMediaMosaicLayout.frames(count: 0, availableWidth: Self.width).isEmpty)
        #expect(MessageMediaMosaicLayout.frames(count: 1, availableWidth: Self.width).isEmpty)
        #expect(MessageMediaMosaicLayout.totalHeight(count: 0) == 0)
        #expect(MessageMediaMosaicLayout.totalHeight(count: 1) == 0)
    }

    @Test("two pictures split the row evenly")
    func twoSplitEvenly() {
        let frames = MessageMediaMosaicLayout.frames(count: 2, availableWidth: Self.width)
        #expect(frames.count == 2)
        let gap = MessageMediaMosaicLayout.gap
        let columnWidth = (Self.width - gap) / 2
        #expect(frames[0] == CGRect(x: 0, y: 0, width: columnWidth, height: MessageMediaMosaicLayout.cellHeight))
        #expect(frames[1] == CGRect(
            x: columnWidth + gap, y: 0, width: columnWidth, height: MessageMediaMosaicLayout.cellHeight
        ))
        #expect(MessageMediaMosaicLayout.totalHeight(count: 2) == MessageMediaMosaicLayout.cellHeight)
    }

    @Test("three pictures form a hero-and-stack triptych, not a grid")
    func threeFormATriptych() {
        let frames = MessageMediaMosaicLayout.frames(count: 3, availableWidth: Self.width)
        #expect(frames.count == 3)
        // The hero spans the whole triptych height at the leading column.
        #expect(frames[0].minX == 0)
        #expect(frames[0].height == MessageMediaMosaicLayout.triptychHeight)
        // The other two stack in the trailing column, splitting its height with one gap.
        #expect(frames[1].minX == frames[2].minX)
        #expect(frames[1].minX > frames[0].maxX)
        #expect(frames[1].minY == 0)
        #expect(frames[2].minY > frames[1].maxY)
        #expect(MessageMediaMosaicLayout.totalHeight(count: 3) == MessageMediaMosaicLayout.triptychHeight)
    }

    @Test("four pictures are two even rows")
    func fourAreTwoRows() {
        let frames = MessageMediaMosaicLayout.frames(count: 4, availableWidth: Self.width)
        #expect(frames.count == 4)
        // Two rows of two, second row directly below the first with one gap.
        #expect(frames[0].minY == frames[1].minY)
        #expect(frames[2].minY == frames[3].minY)
        #expect(frames[2].minY > frames[0].maxY)
        let expectedHeight = MessageMediaMosaicLayout.cellHeight * 2 + MessageMediaMosaicLayout.gap
        #expect(MessageMediaMosaicLayout.totalHeight(count: 4) == expectedHeight)
    }

    @Test("an odd count past three spans its last picture across the final row")
    func oddTailSpansTheRow() throws {
        let frames = MessageMediaMosaicLayout.frames(count: 5, availableWidth: Self.width)
        #expect(frames.count == 5)
        // Two full rows of two, then a fifth cell spanning the whole width.
        let last = try #require(frames.last)
        #expect(last.width == Self.width)
        #expect(last.minX == 0)
        let expectedHeight = MessageMediaMosaicLayout.cellHeight * 3 + MessageMediaMosaicLayout.gap * 2
        #expect(MessageMediaMosaicLayout.totalHeight(count: 5) == expectedHeight)
    }

    @Test("the mosaic never draws wider than its cap, whatever width it is offered")
    func neverExceedsTheCap() {
        for count in 2 ... 8 {
            for width in [1, 120, Self.width, 900] as [CGFloat] {
                let frames = MessageMediaMosaicLayout.frames(count: count, availableWidth: width)
                for frame in frames {
                    #expect(frame.maxX <= Self.width + 0.01)
                    #expect(frame.width > 0)
                    #expect(frame.height > 0)
                }
            }
        }
    }

    @Test("a degenerate proposal falls back to the maximum width rather than a degenerate one")
    func survivesDegenerateProposals() {
        for width in [0, -50, CGFloat.nan, .infinity, -.infinity] as [CGFloat] {
            let frames = MessageMediaMosaicLayout.frames(count: 3, availableWidth: width)
            #expect(frames.count == 3)
            for frame in frames {
                #expect(frame.width > 0 && frame.width.isFinite)
                #expect(frame.height > 0 && frame.height.isFinite)
            }
        }
    }
}

// MARK: - The layout, hosted

extension MessageMediaMosaicLayoutTests {
    /// The property that matters: the same count reserves the same total height no matter
    /// what is inside each cell — an unloaded placeholder, a decoded photograph, or
    /// nothing at all. That is the no-jump guarantee restated for a group instead of one
    /// picture.
    @MainActor
    @Test("the reservation ignores its cells' content, for every group size")
    func hostedReservationIgnoresItsContent() {
        let proposal = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)

        func measure(count: Int, leafSize: CGFloat) -> CGSize {
            let reservation = MessageMediaMosaicReservation(count: count) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Color.red.frame(width: leafSize, height: leafSize)
                }
            }
            return UIHostingController(rootView: reservation).sizeThatFits(in: proposal)
        }

        for count in [2, 3, 4, 5] {
            let placeholder = measure(count: count, leafSize: 8)
            let loaded = measure(count: count, leafSize: 4000)
            #expect(placeholder == loaded)
            #expect(placeholder.height == MessageMediaMosaicLayout.totalHeight(count: count))
        }
    }
}
