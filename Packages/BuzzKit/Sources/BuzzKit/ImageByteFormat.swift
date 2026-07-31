import Foundation

/// What a picture *is*, read from its own first bytes.
///
/// # Why the bytes and not the filename
///
/// The one question this answers is whether the relay will store what the author
/// picked, and the relay decides that on content. A photo library hands out an
/// asset whose declared type depends on which representation was asked for, and a
/// file's extension is a claim rather than a fact — an iPhone screenshot saved
/// from a share sheet is routinely a `.jpg` holding a PNG. So the header decides,
/// and the extension is never consulted.
///
/// # Why HEIC is a case here at all
///
/// It is the one format an iPhone produces by default and the relay does not
/// store (see ``MediaUploadClient/supportedImageTypes``), so it is the single
/// reason the picking side has to re-encode anything. Naming it as a case, rather
/// than letting it fall out as "unrecognised", is what lets the composer tell the
/// difference between *a photo that needs converting* and *a file that is not a
/// picture at all*.
///
/// The brand scan mirrors the mobile client's `_looksLikeHeicOrHeif`
/// (`buzz/mobile/lib/shared/relay/media_upload.dart`) exactly, including the walk
/// past the major brand into the compatible-brands list: an iPhone writes some
/// HEICs with a major brand of `mif1` and the recognisable brand several entries
/// in, so reading only the major brand misses them.
public enum ImageByteFormat: String, Sendable, Equatable, CaseIterable {
    case jpeg
    case png
    case gif
    case webp
    case heic

    /// The MIME type these bytes are sent as.
    public var mimeType: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .gif: "image/gif"
        case .webp: "image/webp"
        case .heic: "image/heic"
        }
    }

    /// Whether the relay stores this format as it stands — the transcode decision,
    /// derived from the upload client's own list rather than restated, so the two
    /// cannot drift apart.
    public var isStoredByRelay: Bool {
        MediaUploadClient.supportedImageTypes.contains(mimeType)
    }

    /// The format `data` is in, or `nil` when nothing here recognises it.
    ///
    /// `nil` is not "broken": it is every format this client has no opinion about,
    /// and the caller's response is the same as for HEIC — re-encode it into
    /// something the relay stores, and find out then whether it was a picture.
    public static func detect(_ data: Data) -> ImageByteFormat? {
        // Re-based to zero: `data` may itself be a slice of a larger buffer, whose
        // indices do not start at 0, and every offset below is from the start of
        // the file. 32 bytes is what the HEIC brand walk reads at most.
        let header = [UInt8](data.prefix(32))

        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if matches(header, "GIF87a", at: 0) || matches(header, "GIF89a", at: 0) { return .gif }
        if matches(header, "RIFF", at: 0), matches(header, "WEBP", at: 8) { return .webp }
        if isISOBaseMedia(header), hasHEICBrand(header) { return .heic }
        return nil
    }

    // MARK: - Header reading

    /// ISO base media (`… ftyp …`), the container HEIC shares with MP4.
    private static func isISOBaseMedia(_ header: [UInt8]) -> Bool {
        header.count >= 12 && matches(header, "ftyp", at: 4)
    }

    /// The brands recognised as HEIC, in the same set the mobile client carries.
    private static let heicBrands: Set<String> = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1",
    ]

    /// Whether any brand in the `ftyp` box — major *or* compatible — is a HEIC one.
    private static func hasHEICBrand(_ header: [UInt8]) -> Bool {
        var offset = 8
        while offset + 4 <= header.count {
            // ASCII rather than UTF-8: a brand is four ASCII characters by
            // definition, and a lossy decode would turn arbitrary bytes into
            // replacement characters that could never match anyway.
            let brand = String(bytes: header[offset ..< offset + 4], encoding: .ascii)
            if let brand, heicBrands.contains(brand.lowercased()) { return true }
            offset += 4
        }
        return false
    }

    /// Whether `header` holds `string`'s ASCII at `offset`, false rather than a
    /// trap when it is too short to say.
    private static func matches(_ header: [UInt8], _ string: String, at offset: Int) -> Bool {
        let ascii = Array(string.utf8)
        guard header.count >= offset + ascii.count else { return false }
        return Array(header[offset ..< offset + ascii.count]) == ascii
    }
}
