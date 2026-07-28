import UIKit

/// The identity of one image load: a change in either field means a fresh decode.
///
/// A value type rather than a pair of stored properties on the view, because the *pair*
/// is the thing that has to be compared — `.task(id:)` restarts on it, and
/// ``RemoteImageDisplay/drawn(resolved:request:cached:)`` decides what to draw from it.
struct RemoteImageRequest: Equatable {
    /// The artwork's source, or `nil` when this view has none to show.
    let url: URL?
    /// The longest edge, in pixels, the bitmap is decoded to.
    let pixelSize: CGFloat
}

/// A decoded image together with the request it answered.
///
/// The request travels *with* the image rather than beside it because `@State` survives a
/// view whose inputs changed: without the pairing, a recycled row would go on drawing the
/// previous subject's artwork until the new one arrived.
struct RemoteImageResolved {
    let request: RemoteImageRequest
    let image: UIImage
}

/// The rule every remote-image view draws by: which of the images in hand belongs on
/// screen this frame.
///
/// # Why this is one shared function and not a rule per view
///
/// It is the whole no-flicker contract, and it is subtle in a way that is invisible when
/// it is broken — the failure mode is a list that blanks for a few frames, which reads as
/// "the network is slow" rather than as a bug. ``AvatarView`` and ``MessageMediaView``
/// have different frames, different fallbacks and different pixel sizes, but exactly the
/// same question about which bitmap to draw, so they ask it here.
///
/// Three sources, in falling order of exactness, and the ordering is the whole logic:
///
/// 1. resolved state for this exact request — the common case while nothing changes;
/// 2. the loader's cache at the current pixel size, read synchronously. That is a pure
///    read of a thread-safe cache and cannot itself invalidate the view: if it hits, the
///    artwork is drawn a frame earlier than `.task` could manage, because `.task` runs
///    *after* the frame it is attached to;
/// 3. resolved state for the *same subject at another resolution*. Redrawing it costs
///    nothing — the frame is fixed independently of the content — and it is the difference
///    between a Dynamic Type change or a rotation re-rendering a list and blanking it
///    first.
///
/// A resolved image for a *different* URL is never drawn at any point in that chain: it
/// belongs to a subject the view is no longer showing, which is the one thing the identity
/// check exists to refuse.
enum RemoteImageDisplay {
    /// The image to draw right now, or `nil` when there is nothing yet.
    ///
    /// `cached` is a closure rather than a value because it must not be consulted when
    /// resolved state already answers exactly — for a `data:` source that lookup digests
    /// the whole URI, on the main actor, inside `body`.
    ///
    /// `nonisolated` and free of any view type because it is a pure function of its
    /// arguments: a `View`'s conformance puts its caller on the main actor, which this rule
    /// has no need of and which would otherwise make `cached` a value the caller has to
    /// send across an isolation boundary.
    static func drawn(
        resolved: RemoteImageResolved?,
        request: RemoteImageRequest,
        cached: (URL, CGFloat) -> UIImage?
    ) -> UIImage? {
        guard let url = request.url else { return nil }
        let sameSubject = resolved.flatMap { $0.request.url == url ? $0 : nil }
        if let sameSubject, sameSubject.request.pixelSize == request.pixelSize {
            return sameSubject.image
        }
        return cached(url, request.pixelSize) ?? sameSubject?.image
    }
}
