@testable import Hive
import SwiftUI
import Testing
import UIKit

/// The one test in the suite that looks at pixels.
///
/// # Why this exists when `TypographyTests` already covers the same ground
///
/// Every other check of a message's type reads the *intent* our code produced: that a
/// bold run resolved the named Inter face at the right weight, that a code run carries a
/// background, that the spacing ladder cannot invert. Those are honest — the font is
/// chosen in our code now, so a unit test probes the path the app takes — but they all
/// stop one step short of the screen.
///
/// That step is where this class of defect has actually shipped, twice. A message body is
/// drawn by ``RichTextEntityRenderer``, a custom `TextRenderer` whose own documentation
/// says nothing is drawn unless it is drawn there. Something can resolve perfectly and
/// still never reach a pixel. Nothing but a rendered comparison catches that.
///
/// # Why one image and not a suite of them
///
/// A snapshot fails on every intended change as loudly as on a regression, so a wall of
/// them trains everyone to regenerate without looking. One image is the smallest thing
/// that still catches "the highlight stopped drawing" — and when it does fail, the diff
/// is one picture a human can read.
///
/// # What it does not cover
///
/// The inline layer and the blocks that draw in a single layout pass. Tables and fenced
/// code blocks are excluded on purpose — see ``sampler``. This gate is not a claim that
/// the whole message surface is pixel-checked.
///
/// # Regenerating
///
/// Deliberately manual, and deliberately not a flag anyone passes by habit:
///
/// ```
/// HIVE_RECORD_SNAPSHOTS=1 xcodebuild test -scheme Hive …
/// ```
///
/// Then **look at the new image** before committing it. A regenerated reference nobody
/// examined is worse than no reference at all: it launders a regression into the gate.
@MainActor
@Suite("Rendered markdown")
struct RichTextRenderingTests {
    @Test(
        "a message carrying every construct renders as recorded",
        .enabled(if: RenderReference.existsForThisRuntime)
    )
    func samplerMatchesItsReference() throws {
        let rendered = try #require(Self.render(Self.sampler), "the renderer produced no image")
        let reference = Self.referenceURL
        let expected = try #require(UIImage(contentsOfFile: reference.path), "reference is not an image")
        let difference = try Self.difference(between: rendered, and: expected)
        // A tolerance rather than an exact match: the same view rendered on two machines
        // can differ in the last bit of a subpixel-antialiased edge. 1% of full scale is
        // far below any change a reader would notice and far above that noise — a
        // substituted face or a missing highlight moves it by an order of magnitude more.
        #expect(
            difference <= Self.tolerance,
            """
            rendered output differs from the reference by \(difference), above \(Self.tolerance). \
            The actual image is at \(Self.failureURL.path) — compare the two by eye before \
            regenerating, because this test exists to catch the change you are about to bless.
            """
        )
    }

    /// Always runs, on every runtime — this is what CI keeps when the exact comparison
    /// above has no reference to speak for it. It also owns recording, because the
    /// comparison cannot: a test gated on the reference existing can never be the thing
    /// that creates it.
    @Test("the rendered fixture is not a blank canvas")
    func theFixtureActuallyDraws() throws {
        // The failure that makes a snapshot gate worthless: a reference recorded from a
        // view that drew nothing matches a view that draws nothing, and the suite stays
        // green over an empty screen. So the fixture's own ink is asserted, separately
        // from what it is compared against.
        let rendered = try #require(Self.render(Self.sampler))
        if Self.isRecording {
            try Self.record(rendered, to: Self.referenceURL)
            Issue.record("Recorded \(Self.referenceURL.lastPathComponent). Look at it, then re-run without recording.")
        }
        let ink = try Self.inkCoverage(of: rendered)
        // Text is mostly background even on a dense screen; 2% is comfortably above what
        // an empty or near-empty render produces and far below this fixture's own ~8%.
        #expect(ink > 0.02, "only \(ink) of the fixture's pixels differ from the background")
    }
}

/// Where the reference lives, and which runtime it is allowed to speak for.
///
/// # Why the iOS version is in the filename
///
/// Text does not lay out identically across iOS releases. Recorded on 26.0 and compared on
/// the CI runner's newer runtime, the same fixture came out a different height — so the
/// comparison did not fail by a few antialiased edges, it failed by the whole image. A
/// reference is therefore valid only for the runtime that produced it, and says so in its
/// own name.
///
/// The consequence, stated plainly rather than hidden: **on a runtime with no reference the
/// comparison does not run.** It reports as skipped, never as passed, because a gate that
/// goes green when it did not execute is worse than no gate. Today that means the exact
/// comparison is a local pre-merge check — the same shape the conversation scroll gate
/// already has in this repo — while CI keeps the render check that *is* portable: the
/// fixture must still draw something.
///
/// A `nonisolated enum` and not part of the suite: `.enabled(if:)` evaluates before the
/// test does, outside its actor.
enum RenderReference {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    /// Major and minor only. A patch release has never moved this fixture, and pinning to
    /// one would expire every reference on a point update nobody's rendering changed.
    static var runtime: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    static var url: URL {
        directory.appendingPathComponent("markdown-rendering-\(runtime).png")
    }

    static var failureURL: URL {
        directory.appendingPathComponent("markdown-rendering-\(runtime).actual.png")
    }

    static var existsForThisRuntime: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Fixture

private extension RichTextRenderingTests {
    /// The constructs this gate can honestly record.
    ///
    /// Held here rather than reused from `ConversationFixture` on purpose: that fixture is
    /// a development aid and changes whenever somebody wants to look at something, which
    /// would invalidate this reference for a reason that has nothing to do with rendering.
    ///
    /// # What is deliberately absent, and why
    ///
    /// A table and a fenced code block are **not** here. `ImageRenderer` resolves one
    /// layout pass, and both of those need more than one: a table's columns are measured
    /// and fed back before they can be drawn, and a code block's highlighting is produced
    /// off the first pass. Rendered through this path they come out as an empty frame —
    /// measured, not assumed, by recording a reference that contained both and looking at
    /// it. Including them would freeze that blank into the reference and call it truth,
    /// which is worse than not covering them: the gate would then go green *because* it
    /// records nothing where the app draws something.
    ///
    /// They are covered where a single pass is not required — `RichTextTableTests` for
    /// column measurement, `RichTextBlockTests` for the spacing that frames both, and the
    /// `-markdownSampler` fixture for a real screen when somebody changes them.
    static let sampler = """
    # Heading one
    ## Heading two
    ### Heading three

    An ordinary paragraph, and a second one after it, so the gap between two paragraphs \
    is part of what this image records.

    **Bold at the weight and size of the sentence around it.** *Italic that leans without \
    shrinking.* ***Both at once.*** ~~Struck through.~~ Inline `code`, `SELECT` and \
    `--flag`, each carrying its own highlight.

    ---

    - A bullet
    - A bullet that wraps onto a second line
      - A nested one

    1. First
    2. Second

    > A quote, which has an edge of its own on the left.

    A closing paragraph, so the reference ends on ordinary text.
    """
}

// MARK: - Rendering

private extension RichTextRenderingTests {
    /// A phone's width, fixed. The image must not depend on which simulator ran it.
    static let width: CGFloat = 393
    /// 1% of full scale. See the tolerance argument at the call site.
    static let tolerance = 0.01
    /// Fixed rather than the device's, for the same reason as the width.
    static let scale: CGFloat = 2

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["HIVE_RECORD_SNAPSHOTS"] == "1"
    }

    static var referenceURL: URL { RenderReference.url }

    /// Written beside the reference, not into it: a failing run leaves something to look
    /// at without overwriting the thing it disagreed with.
    static var failureURL: URL { RenderReference.failureURL }

    static func render(_ markdown: String) -> UIImage? {
        render(
            RichTextView(RichMessage(blocks: RichTextParser.parse(markdown)))
                .padding(16)
                .frame(width: width)
                .background(Color.black)
        )
    }

    /// Every environment value the output depends on is stated, so the image is a function
    /// of the code under test and nothing else — not the simulator's text size, not its
    /// appearance, not its scale.
    static func render(_ content: some View) -> UIImage? {
        let renderer = ImageRenderer(
            content: content
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.layoutDirection, .leftToRight)
        )
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    static func record(_ image: UIImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try #require(image.pngData())
        try data.write(to: url)
    }
}

// MARK: - Comparison

private extension RichTextRenderingTests {
    /// Mean absolute per-channel difference, 0 for identical and 1 for black against white.
    ///
    /// Both images are redrawn into one known 8-bit RGBA context first. Comparing
    /// `pngData()` or raw `CGImage` buffers instead compares the encoder and the colour
    /// space as much as the pixels, which is how a snapshot gate ends up failing for
    /// reasons no reader could see.
    static func difference(between lhs: UIImage, and rhs: UIImage) throws -> Double {
        // Compared in pixels, never in `UIImage.size`: that is points, and a freshly
        // rendered image carries the renderer's scale while one read back off disk carries
        // 1. The two agreed to the pixel and still reported different sizes, which read as
        // a total mismatch — the gate's first false alarm was its own.
        let left = try pixels(of: lhs)
        let right = try pixels(of: rhs)
        guard left.count == right.count, !left.isEmpty else {
            try? record(lhs, to: failureURL)
            // A size change is a difference by definition, and reporting it as full scale
            // keeps the caller from having to special-case it.
            return 1
        }

        var total = 0
        for index in left.indices {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        let mean = Double(total) / Double(left.count) / 255
        if mean > tolerance {
            try? record(lhs, to: failureURL)
        }
        return mean
    }

    /// The fraction of pixels that are not the background — the fixture's own ink.
    static func inkCoverage(of image: UIImage) throws -> Double {
        let buffer = try pixels(of: image)
        guard !buffer.isEmpty else { return 0 }
        var inked = 0
        // The background is drawn black, so any pixel carrying meaningful luminance is a
        // glyph, a rule, a table border or a code block's fill.
        for index in stride(from: 0, to: buffer.count, by: 4)
        where Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2]) > 24 {
            inked += 1
        }
        return Double(inked) / Double(buffer.count / 4)
    }

    static func pixels(of image: UIImage) throws -> [UInt8] {
        let cgImage = try #require(image.cgImage, "image has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            "could not build a comparison context"
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
