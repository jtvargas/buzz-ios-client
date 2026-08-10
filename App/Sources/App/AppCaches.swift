import Foundation

/// The process-wide caches of recomputable things, and the two moments they are dropped.
///
/// These five are `static`, so they are the one kind of state that outlives both a view and a
/// session — the exception to ``AppEnvironment``'s rule that Hive's per-community state *is*
/// this object graph. They are named here rather than reached into from two call sites, so
/// "which caches are there" has one answer and adding a sixth is one edit.
///
/// # Why a suspended app has to be asked
///
/// `NSCache` gives its contents back on the system's memory-pressure signal, and every one of
/// these types says so in its own comment. That is true of a *running* app. A suspended one
/// never gets to act on the signal: its pages stay dirty and count toward the footprint iOS
/// ranks background apps by when it decides whose process to kill. So the only moment Hive can
/// hand this memory back is on the way out, under its own power.
///
/// Nothing here is a source of truth. Every entry is derived from something still on disk or
/// still on the relay, so the worst an over-eager drop can cost is the work of doing it again.
@MainActor
enum AppCaches {
    /// Dropped when the app leaves the screen.
    ///
    /// Media the relay serves as `cache-control: public, max-age=31536000, immutable`, so a
    /// picture that comes back after this costs a decode out of `URLCache` and not a request.
    ///
    /// **Avatars are deliberately not in this list.** ``RemoteImageLoader/shared`` is the
    /// smallest of the five at 16 MB and by far the most visible — every sidebar row, every
    /// message header and every mention draws one — and the synchronous peek that peels them
    /// off it (``RemoteImageLoader/cachedImage(for:pixelSize:)``) is what draws a row's face
    /// in the frame the row appears in rather than one frame later. Dropping them would trade
    /// a sixth of the footprint for a monogram flashing on every visible row on the way back
    /// in. They go with a session instead — see ``releaseAll()``.
    static func releaseSuspendable() {
        // The 48 MB one, and the reason this exists.
        RemoteImageLoader.messageMedia.removeAll()
        // 32 MB of avatar-editor tiles, held for the life of the process after one browse.
        AvatarKitThumbnails.removeAll()
        RichMessageCache.removeAll()
        RichCodeHighlighter.removeAll()
    }

    /// Everything, avatars included: the identity that filled these no longer owns the app.
    ///
    /// Said from ``AppEnvironment/teardownSession()``, which is a sign-out, a community switch
    /// and the different-key wipe. No *wrong* render was ever possible across that boundary —
    /// ``RichMessageCache`` keys on the resolver's identity and media URLs are content-addressed
    /// — so this is custody rather than correctness: one reader's faces and message text should
    /// not still be in memory after another has signed in.
    static func releaseAll() {
        releaseSuspendable()
        RemoteImageLoader.shared.removeAll()
    }
}
