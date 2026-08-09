import Foundation

/// What this device refuses to upload, and why — the local half of the relay's own
/// rules for the generic-file route.
///
/// # Why any of this is here rather than only on the relay
///
/// **So an unsupported pick fails on this device with a name for what went wrong,
/// instead of costing an upload of the bytes to be told the same thing.** That was
/// the reason the picture-only guard this replaces existed, and it is a better
/// reason now than it was then: a picture is a few megabytes and a file may be a
/// hundred.
///
/// # It mirrors the relay, it does not duplicate it
///
/// The relay decides from the **bytes** (`buzz-media/src/validation.rs`), which is
/// the only authority that cannot be talked out of its answer, and it stays the
/// authority. Everything below is a cheap pre-check on what the *name* claims, so a
/// type that passes here may still come back ``MediaUploadError/rejectedByPolicy``.
/// The two failing differently is expected and is not a bug in either.
///
/// # Audio is the surprising refusal, and it is deliberately absent below
///
/// The relay rejects anything it sniffs as `audio/*` — "until Buzz has an explicit
/// sanitizer and location-metadata validator for its container"
/// (`validation.rs:188-195`). It is not in ``blockedFileTypes`` because a container's
/// *declared* type is a poor guide to what the sniffer will call it, and a local
/// refusal that disagrees with the relay is worse than no local refusal at all: it
/// would block files the platform would have taken, on this client only.
public extension MediaUploadClient {
    /// The types the relay refuses on its generic-file route, whatever they are named.
    ///
    /// A mirror of `BLOCKED_FILE_MIME_TYPES` (`buzz-media/src/validation.rs:75`):
    /// active web content, which would be a stored-XSS vector, and native
    /// executables and installers.
    static let blockedFileTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml",
        "application/javascript", "text/javascript",
        "application/x-msdownload", "application/x-executable",
        "application/vnd.microsoft.portable-executable",
        "application/x-mach-binary", "application/x-sharedlib", "application/x-elf",
        "application/x-msi", "application/vnd.android.package-archive",
        "application/x-apple-diskimage",
    ]

    /// The largest file the relay stores — `default_max_file_bytes`
    /// (`buzz-media/src/config.rs:40`), which is also the mobile client's own cap.
    static let maxFileBytes = 100 * 1024 * 1024

    /// Why these bytes are not worth sending, or `nil` when they are.
    ///
    /// Applied by the composer at *pick* time as well as by the uploader, so a refusal
    /// reaches the author while they are still composing rather than when the message
    /// tries to go.
    static func policyFailure(mimeType: String, byteCount: Int) -> MediaUploadError? {
        if byteCount > maxFileBytes { return .tooLarge(bytes: byteCount, max: maxFileBytes) }
        if blockedFileTypes.contains(mimeType) { return .unsupportedType(mimeType) }
        return nil
    }
}
