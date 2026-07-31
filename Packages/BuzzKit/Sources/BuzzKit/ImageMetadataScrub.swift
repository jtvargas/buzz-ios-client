import Foundation

/// Strips every byte of metadata the relay refuses to store, without decoding the picture.
///
/// # Why this exists
///
/// The relay does not merely ignore metadata, it **rejects** it. From its own validator
/// (`crates/buzz-media/src/validation.rs`), a JPEG may carry exactly two non-image segments —
/// a canonical JFIF `APP0` and a 12-byte Adobe `APP14` — and everything from `APP1` through
/// `APP13`, plus `APP15` and the comment segment, is `MetadataForbidden`, which reaches the
/// client as a bare 422. `APP1` is EXIF and `APP2` is the colour profile, so **every photograph
/// an iPhone has ever taken carries two segments that are refused on sight**.
///
/// That was shipped once without this and the owner found it on his own phone within minutes:
/// most of his library came back "the relay wouldn't store that picture".
///
/// # Why re-encoding is not enough
///
/// Encoding a `UIImage` afresh does not produce a bare file. The system encoder writes a colour
/// profile back in for anything rendered in the device's own wide-gamut range, so the JPEG
/// produced *by the fix* is refused for the same reason as the photo that went in. Rendering
/// into sRGB explicitly is what removes the need for a profile, and a byte scrub afterwards is
/// what proves it — see ``ComposerImagePreparation`` in the app, which does both.
///
/// # Why a scrub and not a decode, for animations
///
/// A GIF, an animated PNG or an animated WebP put through a decode-and-re-encode comes back as
/// a single still frame, and it reports success while doing it. So the animated formats are
/// walked structurally: keep the chunks the relay's allowlist keeps, drop the rest, and leave
/// frame data, timing, disposal and looping exactly where they were.
///
/// # Provenance
///
/// This is a port, not an invention. The rules are the mobile client's
/// `mobile/ios/Runner/MediaSanitizer.swift` (stills) and
/// `mobile/lib/shared/relay/animated_image_sanitizer.dart` (animations), which are themselves
/// written against the relay validator above. Where the three could drift, the relay wins: its
/// check and ``keepsJPEGSegment(marker:)`` below are the same rule stated twice.
public enum ImageMetadataScrub {
    public enum Failure: Error, Equatable {
        case notJPEG
        case notPNG
        case notGIF
        case notWebP
        /// The bytes ran out mid-structure, so nothing here can say what they were.
        case truncated
        /// An animation carries something that cannot be removed without decoding it —
        /// an ICC profile, or an EXIF orientation that is actually rotating the picture.
        /// Flattening it to fix that would silently throw the animation away.
        case unremovableFromAnimation
    }

    // MARK: - EXIF orientation

    /// Whether an EXIF payload actually turns the picture.
    ///
    /// Only asked of animations, and only to refuse them: orientations 2–8 mean the stored
    /// pixels are not what the viewer should see, so dropping the tag silently rotates the
    /// picture. Orientation 1, or no tag at all, is nothing to lose.
    static func rotates(exifOrientationIn bytes: [UInt8], at start: Int, length: Int) -> Bool {
        guard let orientation = exifOrientation(bytes, at: start, length: length) else { return false }
        return (2 ... 8).contains(orientation)
    }

    static func exifOrientation(_ bytes: [UInt8], at start: Int, length: Int) -> Int? {
        let end = start + length
        guard end <= bytes.count else { return nil }
        var tiff = start
        // A JPEG-style `Exif\0\0` prefix, which the WebP and PNG carriers may or may not repeat.
        if length >= 6, matches(bytes, "Exif", at: start), bytes[start + 4] == 0, bytes[start + 5] == 0 {
            tiff += 6
        }
        guard end - tiff >= 8 else { return nil }

        let littleEndian: Bool
        switch (bytes[tiff], bytes[tiff + 1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        func uint16(_ offset: Int) -> Int? {
            guard offset >= tiff, offset + 2 <= end else { return nil }
            return littleEndian
                ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                : Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func uint32(_ offset: Int) -> Int? {
            guard offset >= tiff, offset + 4 <= end else { return nil }
            return littleEndian
                ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
                : Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }

        guard uint16(tiff + 2) == 42, let ifdOffset = uint32(tiff + 4) else { return nil }
        let ifd = tiff + ifdOffset
        guard let entries = uint16(ifd) else { return nil }
        for index in 0 ..< entries {
            let entry = ifd + 2 + index * 12
            // Tag 0x0112 (orientation), type 3 (short), one value.
            if uint16(entry) == 0x0112, uint16(entry + 2) == 3, uint32(entry + 4) == 1 {
                return uint16(entry + 8)
            }
        }
        return nil
    }

    // MARK: - Reading

    static func readUInt32BigEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func readUInt32LittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func uint32LittleEndian(_ value: Int) -> [UInt8] {
        let value = UInt32(value)
        return [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ]
    }

    static func matches(_ bytes: [UInt8], _ string: String, at offset: Int) -> Bool {
        let ascii = Array(string.utf8)
        guard bytes.count >= offset + ascii.count else { return false }
        return Array(bytes[offset ..< offset + ascii.count]) == ascii
    }

    static func matches(_ bytes: ArraySlice<UInt8>, _ string: String, at offset: Int) -> Bool {
        matches(Array(bytes), string, at: offset)
    }
}
