import Foundation

/// The JPEG half of ``ImageMetadataScrub`` — see that type for why any of this exists.
extension ImageMetadataScrub {
// MARK: - JPEG

    /// Everything but the two segments the relay permits.
    ///
    /// `APP0` must be a *canonical* JFIF header — its length is fixed by its own thumbnail
    /// dimensions — and `APP14` a 12-byte Adobe marker. Accepting arbitrary payloads under
    /// either would leave exactly the metadata side channel the relay is refusing.
    public static func scrubJPEG(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw Failure.notJPEG }

        var output = Data([0xFF, 0xD8])
        var offset = 2
        var inScan = false
        while offset < bytes.count {
            // Entropy-coded data: copy it verbatim up to the next marker. `0xFF` inside a scan
            // is either a stuffed byte or a restart marker, and both are handled below.
            if inScan, bytes[offset] != 0xFF {
                let next = bytes[offset...].firstIndex(of: 0xFF) ?? bytes.count
                output.append(contentsOf: bytes[offset ..< next])
                offset = next
                continue
            }
            guard bytes[offset] == 0xFF else { throw Failure.notJPEG }

            let markerStart = offset
            // Fill bytes: any run of 0xFF before a marker is legal padding.
            while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
            guard offset < bytes.count else { throw Failure.truncated }

            let marker = bytes[offset]
            offset += 1
            // A stuffed 0xFF00, or a restart marker: part of the scan, never a segment.
            if inScan, marker == 0x00 {
                output.append(contentsOf: bytes[markerStart ..< offset])
                continue
            }
            if (0xD0 ... 0xD7).contains(marker) || marker == 0x01 {
                output.append(contentsOf: bytes[markerStart ..< offset])
                continue
            }
            if marker == 0xD9 {
                output.append(contentsOf: bytes[markerStart ..< offset])
                return output
            }
            guard marker != 0xD8, bytes.count - offset >= 2 else { throw Failure.notJPEG }

            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else { throw Failure.notJPEG }
            let segmentEnd = offset + length
            if keepsJPEGSegment(marker, bytes: bytes, payload: (offset + 2) ..< segmentEnd) {
                output.append(contentsOf: bytes[markerStart ..< segmentEnd])
            }
            offset = segmentEnd
            inScan = marker == 0xDA
        }
        throw Failure.truncated
    }

    /// The relay's allowlist, stated as a predicate.
    static func keepsJPEGSegment(_ marker: UInt8, bytes: [UInt8], payload: Range<Int>) -> Bool {
        switch marker {
        case 0xE0:
            // JFIF, and only if its declared thumbnail accounts for its whole length.
            guard payload.count >= 14,
                  Array(bytes[payload.lowerBound ..< payload.lowerBound + 5]) == Array("JFIF\0".utf8)
            else { return false }
            let width = Int(bytes[payload.lowerBound + 12])
            let height = Int(bytes[payload.lowerBound + 13])
            return payload.count == 14 + 3 * width * height
        case 0xEE:
            return payload.count == 12
                && Array(bytes[payload.lowerBound ..< payload.lowerBound + 5]) == Array("Adobe".utf8)
        case 0xE1 ... 0xED, 0xEF, 0xFE:
            // EXIF, ICC, XMP, Photoshop, comments — the whole refused range.
            return false
        default:
            // Quantisation tables, Huffman tables, frame and scan headers: the picture itself.
            return true
        }
    }
}
