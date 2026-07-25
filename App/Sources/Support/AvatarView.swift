import ImageIO
import SwiftUI
import UIKit

/// A circular avatar that downsamples remote artwork to its display size before
/// decoding, with a stable monogram fallback.
///
/// # Why not a bare `AsyncImage`
///
/// `AsyncImage` decodes an image at full resolution regardless of the frame it lands
/// in: a 2000×2000 profile picture becomes a ~16 MB bitmap to fill a 44-pt circle, and
/// a timeline of them decoded on the main thread spikes both memory and scroll latency.
/// This view instead downsamples with ImageIO (`CGImageSourceCreateThumbnailAtIndex`)
/// to the exact pixel size the display needs, off the main thread, and caches the
/// result — so a row that scrolls away and back reuses a small bitmap rather than
/// re-decoding a large one. That is the avatar half of the scroll-performance pass.
struct AvatarView: View {
    /// The artwork URL, or `nil` to show the monogram.
    let url: URL?
    /// A stable seed for the monogram colour — a channel id or a pubkey — so a given
    /// subject keeps the same tint across launches.
    let seed: String
    /// The letter shown when there is no artwork.
    let initial: String
    /// The avatar's point size.
    var size: CGFloat = 44

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        // Reload when the artwork or the pixel size it must be decoded to changes.
        .task(id: TaskKey(url: url, pixels: pixelSize)) {
            await load()
        }
        .accessibilityHidden(true)
    }

    /// The pixel size the artwork should be decoded to — points × display scale.
    private var pixelSize: CGFloat { size * displayScale }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let decoded = await AvatarLoader.shared.image(for: url, pixelSize: pixelSize)
        // The `.task(id:)` was cancelled if the row was reused for another subject; only
        // apply when this task is still the current one.
        if !Task.isCancelled {
            image = decoded
        }
    }

    private var monogram: some View {
        Circle()
            .fill(Color(hue: Self.hue(for: seed), saturation: 0.5, brightness: 0.8).gradient)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
    }

    /// A stable hue in `0...1` from a seed — a byte sum, not `hashValue` (which is
    /// randomised per launch and would flicker a subject's colour between runs).
    static func hue(for seed: String) -> Double {
        let sum = seed.utf8.reduce(0) { $0 &+ Int($1) }
        return Double(sum % 360) / 360
    }

    /// The identity of one load: a change in either field means a fresh decode.
    private struct TaskKey: Equatable {
        let url: URL?
        let pixels: CGFloat
    }
}

/// Loads, downsamples, caches, and de-duplicates avatar image requests.
///
/// An actor so the cache and the in-flight table are mutated without a lock, and so a
/// burst of rows asking for the same URL while scrolling shares one network+decode
/// rather than starting a request each. Decoding runs on the actor's executor (off the
/// main thread), which also serialises decodes into a steady trickle instead of a
/// thundering herd on first paint.
actor AvatarLoader {
    static let shared = AvatarLoader()

    /// Keyed by URL and target pixel size, so the same artwork at two sizes caches
    /// separately and a re-request at the same size is a hit. `NSCache` evicts under
    /// memory pressure on its own.
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        cache.countLimit = 256
    }

    /// The downsampled avatar for `url` at `pixelSize`, from cache when present,
    /// otherwise fetched and decoded once even under concurrent callers.
    func image(for url: URL, pixelSize: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(pixelSize.rounded()))"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let session = session
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixelSize: pixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// Decodes `data` straight to a thumbnail no larger than `maxPixelSize` on its
    /// longest edge, so a large source never becomes a large in-memory bitmap. `nil`
    /// for data ImageIO cannot read.
    nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}
