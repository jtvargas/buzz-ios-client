import SwiftUI
import UIKit

/// One cell of the option grid, as the value that decides its pixels: the layers to paint,
/// the ground behind them, and the window of the 306-unit design space to paint through.
///
/// # Why this holds resolved layer names rather than an ``AvatarKitAvatar``
///
/// It is what makes the cache work rather than thrash. A cell shows the *whole* avatar with
/// one layer swapped, so every cell of the hair layer already carries the hair it offers —
/// which means choosing a different hair leaves all thirty-three of those cells describing
/// exactly the pictures they were describing a moment ago. Keyed by the avatar instead, every
/// one of them would look new. Tapping around inside a layer is what this screen does
/// ninety-nine times out of a hundred, and it must not cost a single redraw.
///
/// It also makes two recipes that paint the same picture one entry: the ground is the only
/// thing that separates the nine colour cells, and their eight layers are shared.
struct AvatarKitThumbnail: Hashable, Sendable {
    let layers: [String]
    /// The `#RRGGBB` behind the drawing, or `nil` for the transparent ground.
    let ground: String?
    let window: CGRect

    init(avatar: AvatarKitAvatar, window: CGRect) {
        layers = avatar.layers
        ground = avatar.background.hex
        self.window = window
    }

    /// The cache key. Every field that reaches a pixel is in it and nothing else is, so two
    /// requests that would draw the same square are the same string.
    var key: NSString {
        let box = "\(Int(window.minX)),\(Int(window.minY)),\(Int(window.width))"
        return "\(box)|\(ground ?? "-")|\(layers.joined(separator: "+"))" as NSString
    }
}

/// The rasterised thumbnails the option grid draws, drawn once and kept.
///
/// # Why the grid does not simply stack the artwork per cell
///
/// A cell is the whole avatar — up to eight layers of it — and sixteen of them are on screen
/// at once. Live, that is over a hundred and thirty image views being laid out and composited
/// on every frame of a scroll, each one of them a vector asset the system has to rasterise.
/// A bitmap costs one. The measurement that decided it is in ``AvatarKitEditorFixture``.
///
/// # Why `ImageRenderer` and not a hand-rolled Core Graphics composite
///
/// A Core Graphics pass could run off the main actor, which is tempting. But the artwork is
/// SVG with `preserves-vector-representation`, and what re-rasterises it cleanly at a new size
/// is SwiftUI's own draw of it — `UIImage.draw(in:)` scales whatever bitmap the asset happens
/// to be holding. ``AvatarKitExport`` reached the same conclusion for the same reason: the
/// only way the thumbnail, the preview and the uploaded picture cannot drift is that one view
/// draws all three. So the render is on the main actor, and ``prewarm(_:)`` is what keeps it
/// off the frame the reader is looking at.
@MainActor
enum AvatarKitThumbnails {
    /// The side every thumbnail is drawn at, in points, and the scale it is drawn at.
    ///
    /// Fixed rather than taken from the cell that asked, so one raster serves every phone
    /// width and no geometry has to go into the key. 96pt at 3x is 288 real pixels — a shade
    /// more than the widest cell a 402pt phone produces (83pt, so 249px), which means the
    /// grid only ever scales these *down*.
    static let side: CGFloat = 96
    private static let scale: CGFloat = 3

    /// What has been drawn.
    ///
    /// `NSCache` rather than a dictionary for the one thing a dictionary cannot do: hand the
    /// lot back when the system is short of memory. This screen is a sheet over a running
    /// app, and it is holding tens of megabytes of bitmaps that can all be redrawn.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Bytes rather than entries. One entry is 288 × 288 × 4 ≈ 324 KB, so this holds a
        // hundred — every cell of the largest layer, three shuffles deep. Left uncapped, a
        // long browse across all eight layers would keep every avatar it ever drew.
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// The thumbnail if it has been drawn, without drawing it.
    ///
    /// Separate from ``image(for:)`` so a cell can ask this from its `body` — see
    /// ``AvatarKitThumbnailView``, where the frame that answer saves is the whole point.
    static func cached(_ thumbnail: AvatarKitThumbnail) -> UIImage? {
        cache.object(forKey: thumbnail.key)
    }

    /// The thumbnail, drawing it if it has not been drawn.
    static func image(for thumbnail: AvatarKitThumbnail) -> UIImage? {
        if let known = cached(thumbnail) { return known }
        guard let drawn = draw(thumbnail) else { return nil }
        cache.setObject(drawn, forKey: thumbnail.key, cost: cost(of: drawn))
        return drawn
    }

    /// Draws `thumbnails` in the order given, yielding between each so the run never holds a
    /// frame, and stopping the moment the task is cancelled.
    ///
    /// # Why the grid prewarms instead of letting each cell draw for itself
    ///
    /// A cell that draws in its own `task` draws while it is scrolling in, which is the one
    /// moment in this screen's life that has no milliseconds to spare. Prewarming moves that
    /// work to the moment a layer is chosen — when the reader has just tapped a chip and is
    /// looking at the top of a grid that is already correct — and by the time a scroll starts
    /// there is nothing left to do. A cell still draws for itself as a fallback, because a
    /// cancelled prewarm must not leave a hole.
    ///
    /// The yield is load-bearing and is not `sleep`: it hands the main actor back between
    /// draws, so the run interleaves with layout and touch handling rather than blocking them
    /// for its whole length.
    static func prewarm(_ thumbnails: [AvatarKitThumbnail]) async {
        for thumbnail in thumbnails {
            if Task.isCancelled { return }
            // No yield on a hit: after a tap inside a layer every cell of it is still valid,
            // and thirty-three hops through the main actor to discover that is thirty-three
            // frames of nothing.
            guard cached(thumbnail) == nil else { continue }
            _ = image(for: thumbnail)
            await Task.yield()
        }
    }

    // MARK: - Drawing

    private static func draw(_ thumbnail: AvatarKitThumbnail) -> UIImage? {
        let renderer = ImageRenderer(content: AvatarKitThumbnailCanvas(thumbnail: thumbnail, side: side))
        renderer.scale = scale
        // Every thumbnail carries a ground of its own — a colour, or the checks that stand
        // for the transparent one — so there is no alpha in any of them. Saying so is what
        // keeps a grid of sixteen of these out of the compositor's blending path.
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }

    // MARK: - Layer heights

    /// ``AvatarKitGeometry/layerHeight(_:)``, remembered.
    ///
    /// That call opens the named asset to read its aspect ratio, and a grid of thirty-three
    /// cells asks it eight times per cell every time one is laid out. The answer is a property
    /// of the artwork and cannot change while the app is running, so it is asked once. A
    /// memo here rather than inside the geometry itself, which the export shares and which
    /// this screen has no business changing the shape of.
    static func height(of name: String) -> CGFloat {
        if let known = heights[name] { return known }
        let height = AvatarKitGeometry.layerHeight(name)
        heights[name] = height
        return height
    }

    private static var heights: [String: CGFloat] = [:]

    #if DEBUG
    /// Draws without consulting or filling the cache. For the fixture's measurement, which
    /// is timing the draw and would otherwise be timing a dictionary.
    static func drawIgnoringCache(_ thumbnail: AvatarKitThumbnail) -> UIImage? {
        draw(thumbnail)
    }
    #endif
}

// MARK: - The canvas

/// The avatar, drawn through a window of the design space.
///
/// # Why this is not ``AvatarKitCanvas``
///
/// That one clips to the 306 square, which is right for an avatar and wrong for a thumbnail:
/// a window can sit partly outside the square — the outfits run to 399 and are chosen by the
/// part of them that hangs below the frame — and it draws its ground only inside the square,
/// which would leave a corner of nothing in any cell whose window overhangs. This draws the
/// ground across the whole tile and lets the layers overhang, which is what a crop needs.
///
/// The offset is what does the work: the layers are laid out at their full scaled size against
/// the tile's top-left, then slid so the window's own top-left is the corner the tile shows.
/// `offset` does not move the box the parent laid out, which is exactly why it can be used to
/// move the picture inside it.
private struct AvatarKitThumbnailCanvas: View {
    let thumbnail: AvatarKitThumbnail
    /// The side of the square to draw into, in points.
    let side: CGFloat

    var body: some View {
        let scale = side / thumbnail.window.width
        layers(scale: scale)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(ground)
            .clipped()
    }

    @ViewBuilder
    private var ground: some View {
        if let hex = thumbnail.ground, let color = Color(avatarHex: hex) {
            color
        } else {
            AvatarKitTransparencyChecks()
        }
    }

    private func layers(scale: CGFloat) -> some View {
        let square = AvatarKitGeometry.designSide * scale
        return ZStack(alignment: .topLeading) {
            ForEach(thumbnail.layers, id: \.self) { name in
                Image(name)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: square, height: AvatarKitThumbnails.height(of: name) * scale)
            }
        }
        .frame(width: square, height: square, alignment: .topLeading)
        .offset(x: -thumbnail.window.minX * scale, y: -thumbnail.window.minY * scale)
    }
}

/// The ground under an avatar that has none.
///
/// The checks are the one drawing every reader already knows means "nothing is here", and
/// this screen needs it said: a transparent avatar is a real choice, it is the first of the
/// nine colour cells, and drawn on a plain white tile it is indistinguishable from the second
/// one. Light rather than dark despite the app being dark throughout, because the artwork is
/// black line on nothing and it has to stay legible standing on this.
private struct AvatarKitTransparencyChecks: View {
    /// Squares across the tile. Eight is fine enough to read as a pattern at 80pt and coarse
    /// enough not to shimmer when the grid scales the raster down.
    private static let divisions = 8
    private static let light = Color(white: 0.94)
    private static let dark = Color(white: 0.82)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.light))
            let step = size.width / CGFloat(Self.divisions)
            for row in 0 ..< Self.divisions {
                for column in 0 ..< Self.divisions where (row + column).isMultiple(of: 2) {
                    let square = CGRect(
                        x: CGFloat(column) * step,
                        y: CGFloat(row) * step,
                        width: step,
                        height: step
                    )
                    context.fill(Path(square), with: .color(Self.dark))
                }
            }
        }
    }
}

// MARK: - The cell's picture

/// A thumbnail: from the cache if it is there, from a draw if it is not.
struct AvatarKitThumbnailView: View {
    let thumbnail: AvatarKitThumbnail

    /// What this cell drew, and *what it drew it for*.
    ///
    /// The pair rather than a bare `UIImage?` so the task below can tell whether the picture it
    /// is holding answers the request it has now — which after a shuffle it does not.
    private struct Drawing {
        let thumbnail: AvatarKitThumbnail
        let image: UIImage
    }

    @State private var drawing: Drawing?

    var body: some View {
        // The cache is asked from the body rather than from the task, which lands a frame later.
        // On a hit — the common case, since a tap inside a layer leaves every one of its cells
        // valid — that frame is a hole where the picture was.
        //
        // The fallback is the picture this cell drew *last*, which is deliberate. A shuffle
        // replaces all thirty-three requests at once, and a cell that showed nothing until its
        // new one arrived would make the whole grid blink. Cells are identified by their option
        // and reset per layer, so the stale picture is always this same option a moment ago —
        // the honest thing to hold up while its replacement is drawn.
        let picture = AvatarKitThumbnails.cached(thumbnail) ?? drawing?.image
        return Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .interpolation(.high)
            } else {
                // Only ever the very first pass of a cell nothing has drawn yet. The cell draws
                // its own ground behind this, so that pass is an empty tile in the grid rather
                // than a hole in it.
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // Unconditional, and that is the whole of it: the cache is not observable, so a body
        // that has already missed will not run again for a hit landing a moment later. This
        // task returning early on "it is in the cache now" left exactly the cells the prewarm
        // reached first — the selected one, every time — showing an empty tile for as long as
        // the screen was open. Assigning it is what invalidates the body that missed.
        .task(id: thumbnail) {
            guard drawing?.thumbnail != thumbnail else { return }
            guard let image = AvatarKitThumbnails.image(for: thumbnail) else { return }
            drawing = Drawing(thumbnail: thumbnail, image: image)
        }
    }
}
