import SwiftUI
import UIKit

/// The shape an avatar is clipped to: Slack's rounded square for people, agents, and
/// channels, and a circle where a round badge still reads better (a large profile
/// header).
enum AvatarShape: Hashable, Sendable {
    case roundedSquare
    case circle

    /// The corner radius at a given point size. The ratio is Slack's — square enough
    /// to be recognisably not-a-circle, round enough not to look sharp at 28pt.
    func cornerRadius(for size: CGFloat) -> CGFloat {
        switch self {
        case .roundedSquare: max(4, size * 0.24)
        case .circle: size / 2
        }
    }
}

/// An avatar that downsamples remote artwork to its display size before decoding,
/// with a stable monogram fallback.
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
///
/// # How it avoids flicker
///
/// Three rules, each load-bearing:
///
/// 1. **State is keyed by identity — the *subject*, not the resolution.** The decoded
///    image is stored with the request it answered, and drawn only while that request's
///    URL is still the one this view is showing. `@State` survives a view whose inputs
///    change, so a row reused for another author would otherwise keep drawing the previous
///    author's face until the new one arrived. The target pixel size is deliberately *not*
///    part of that test: it is derived from a `@ScaledMetric`, so one Dynamic Type step
///    changes it for every avatar on screen at once, and refusing the bitmap in hand there
///    blanked the whole list to monograms until a full round of decodes came back. A good
///    bitmap of the right subject at the wrong resolution is drawn while the new size
///    decodes — free, because the frame is fixed and the content is `.scaledToFill()`.
/// 2. **A cached image is drawn in the first frame.** `.task` runs after the frame it is
///    attached to, so state alone always costs one frame of monogram. The synchronous
///    cache peek in ``body`` closes that gap for artwork already in memory, which while
///    scrolling is nearly all of it.
/// 3. **The swap is not animated.** The frame is fixed independently of the content, so
///    an image arriving replaces pixels without moving anything; letting an ancestor's
///    implicit animation cross-fade that replacement is the one way it reads as a
///    flicker rather than as a load.
struct AvatarView: View {
    /// The artwork URL, or `nil` to show the monogram.
    let url: URL?
    /// A stable seed for the monogram colour — a channel id or a pubkey — so a given
    /// subject keeps the same tint across launches.
    let seed: String
    /// The initials shown when there is no artwork — one or two letters from
    /// ``EntityNames/initials(for:)``, or `?` when nothing is known.
    let monogram: String
    /// The avatar's point size.
    var size: CGFloat = 44
    /// The clip shape; Slack's rounded square by default.
    var shape: AvatarShape = .roundedSquare
    /// The loader to resolve artwork through. Defaults to the shared one; injectable so a
    /// preview or a test can supply its own cache and session.
    var loader: AvatarLoader = .shared

    @State private var resolved: Resolved?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                monogramTile
            }
        }
        // The frame is fixed before the artwork exists, so a picture arriving swaps
        // pixels without moving a single row (spec §7: no layout shift on load).
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: shape.cornerRadius(for: size)))
        // Monogram and image occupy the same box, so there is nothing to animate between
        // them. Clearing the transaction's animation keeps an enclosing `withAnimation`
        // (a list insert, a sheet presentation) from cross-fading the swap into a blink.
        .transaction { $0.animation = nil }
        // Reload when the artwork or the pixel size it must be decoded to changes.
        .task(id: request) { await load() }
        .accessibilityHidden(true)
    }

    /// The identity of one load: a change in either field means a fresh decode.
    ///
    /// Internal rather than private, with ``Resolved``, so ``drawn(resolved:request:cached:)``
    /// can be exercised without a view host — the ordering it encodes is the whole
    /// no-flicker contract.
    struct Request: Equatable {
        let url: URL?
        let pixelSize: CGFloat
    }

    /// A decoded image together with the request it answered.
    struct Resolved {
        let request: Request
        let image: UIImage
    }

    private var request: Request {
        Request(url: url, pixelSize: size * displayScale)
    }

    /// The image to draw right now, or `nil` for the monogram.
    ///
    /// Three sources, in falling order of exactness, and the ordering is the whole logic:
    ///
    /// 1. resolved state for this exact request — the common case while nothing changes;
    /// 2. the loader's cache at the current pixel size, read synchronously. That is a pure
    ///    read of a thread-safe cache and cannot itself invalidate the view: if it hits,
    ///    the artwork is drawn a frame earlier than `.task` could manage;
    /// 3. resolved state for the *same subject at another resolution*, which is what a
    ///    Dynamic Type change leaves behind. Redrawing it costs nothing — the frame is
    ///    fixed and the content is `.scaledToFill()` — and it is the difference between a
    ///    text-size change re-rendering the list and blanking it to monograms first.
    ///
    /// A resolved image for a *different* URL is never drawn at any point in that chain: it
    /// belongs to a subject this view is no longer showing, which is the one thing the
    /// identity check exists to refuse.
    private var displayedImage: UIImage? {
        Self.drawn(resolved: resolved, request: request) { url, pixelSize in
            loader.cachedImage(for: url, pixelSize: pixelSize)
        }
    }

    /// The rule behind ``displayedImage``, as a pure function of the three inputs.
    ///
    /// `cached` is a closure rather than a value because it must not be consulted when
    /// resolved state already answers exactly — for a `data:` avatar that lookup digests
    /// the whole URI, on the main actor, inside `body`.
    ///
    /// `nonisolated` because it is a pure function of its arguments: a `View`'s conformance
    /// puts the type on the main actor, which this rule has no need of and which would
    /// otherwise make `cached` a value the caller has to send across an isolation boundary.
    nonisolated static func drawn(
        resolved: Resolved?,
        request: Request,
        cached: (URL, CGFloat) -> UIImage?
    ) -> UIImage? {
        guard let url = request.url else { return nil }
        let sameSubject = resolved.flatMap { $0.request.url == url ? $0 : nil }
        if let sameSubject, sameSubject.request.pixelSize == request.pixelSize {
            return sameSubject.image
        }
        return cached(url, request.pixelSize) ?? sameSubject?.image
    }

    private func load() async {
        let request = request
        guard let url = request.url else {
            // Guarded because `@State` cannot compare a non-`Equatable` value: assigning
            // `nil` over `nil` would still invalidate the view.
            if resolved != nil { resolved = nil }
            return
        }
        let image = await loader.image(for: url, pixelSize: request.pixelSize)
        // The `.task(id:)` was cancelled if this view moved on to another subject; only
        // apply when this task is still the current one. The identity carried in
        // ``Resolved`` is the belt to this braces — it also covers the frame between the
        // inputs changing and `.task` restarting.
        guard !Task.isCancelled, let image else { return }
        resolved = Resolved(request: request, image: image)
    }

    private var monogramTile: some View {
        Rectangle()
            .fill(Color(hue: Self.hue(for: seed), saturation: 0.5, brightness: 0.8).gradient)
            .overlay {
                Text(monogram)
                    // Deliberately the non-scaling overload: `size` is already a
                    // `@ScaledMetric` at every caller, so a font that scaled again would
                    // compound the two and push the initials out of their own tile at the
                    // accessibility sizes. Same behaviour `.system(size:)` had here.
                    .font(.hive(fixedSize: size * (monogram.count > 1 ? 0.34 : 0.42), weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
    }

    /// A stable hue in `0...1` from a seed — a byte sum, not `hashValue` (which is
    /// randomised per launch and would flicker a subject's colour between runs).
    static func hue(for seed: String) -> Double {
        let sum = seed.utf8.reduce(0) { $0 &+ Int($1) }
        return Double(sum % 360) / 360
    }
}
