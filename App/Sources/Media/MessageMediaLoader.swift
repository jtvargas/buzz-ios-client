import Foundation

extension RemoteImageLoader {
    /// The loader message attachments are drawn through: few large bitmaps, a large
    /// budget.
    ///
    /// Every line of the pipeline is ``RemoteImageLoader``'s — the ImageIO downsample off
    /// the main thread, the shared in-flight table, the expiring negative cache. Only the
    /// cache's *shape* differs, and it has to:
    ///
    /// | | avatar | attachment |
    /// |---|---|---|
    /// | drawn at | 34 pt | up to 320×240 pt |
    /// | decoded bitmap | ~13 KB | ~2.7 MB |
    /// | how many on screen | a dozen | one or two |
    ///
    /// A single cost-bounded cache holding both would let one scroll through a
    /// picture-heavy channel evict every face in the conversation — two hundred avatars'
    /// worth of budget per picture — and the faces would then re-decode on the way back.
    /// Two instances is not a second pipeline; it is the same pipeline with the right
    /// bucket under each caller.
    ///
    /// The numbers: a count limit of two dozen so a long scroll cannot grow the table
    /// without bound, and a cost limit that holds a screen or so of pictures *plus* one
    /// full-screen viewer image (``MessageMediaLayout/viewerMaximumPixelSize``, ~16 MB
    /// for a 4:3 source). `NSCache` evicts under memory pressure on its own, so this is a
    /// ceiling rather than a reservation.
    ///
    /// # One thing this deliberately does not get
    ///
    /// The relay's generated thumbnail. ``RelayMediaURL/thumbnail(for:pixelSize:)`` hands
    /// one back only for requests at or below 320 px, because that is the longest edge the
    /// relay's encoder writes; an inline attachment asks for 320 *points* of longest edge,
    /// which is 640 or 960 px, so message media always fetches the original and always
    /// downsamples it locally. That is the correct answer rather than a missed
    /// optimisation — the thumbnail blown up to a 320-pt box is visibly soft — but it does
    /// mean an attachment costs its full transfer. If that becomes the bottleneck the fix
    /// is a larger generated variant on the relay, not a smaller box here.
    static let messageMedia = RemoteImageLoader(
        cache: RemoteImageCache(countLimit: 24, totalCostLimit: 48 * 1024 * 1024)
    )
}
