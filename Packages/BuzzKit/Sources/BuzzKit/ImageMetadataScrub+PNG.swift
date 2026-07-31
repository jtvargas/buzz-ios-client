import Foundation

/// The PNG half of ``ImageMetadataScrub``, still and animated — see that type for why.
extension ImageMetadataScrub {
// MARK: - PNG

    /// Keeps the critical chunks and the ancillary ones the relay allows.
    ///
    /// The allowed set includes `acTL`, `fcTL` and `fdAT`, which is what lets one function serve
    /// a still PNG and an animated one: an APNG scrubbed here is still animated.
    ///
    /// - Parameter isAnimated: when true, a chunk that would need a decode to remove — an ICC
    ///   profile, or an `eXIf` orientation that is really rotating the frame — throws rather
    ///   than being dropped, because dropping it changes how the picture looks and re-encoding
    ///   it would cost the animation.
    public static func scrubPNG(_ data: Data, isAnimated: Bool = false) throws -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count, Array(bytes.prefix(signature.count)) == signature else {
            throw Failure.notPNG
        }

        var output = Data(signature)
        var offset = signature.count
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else { throw Failure.truncated }
            let payloadLength = Int(readUInt32BigEndian(bytes, at: offset))
            guard payloadLength <= bytes.count - offset - 12 else { throw Failure.notPNG }
            let chunkLength = payloadLength + 12
            let typeStart = offset + 4
            guard let type = String(bytes: bytes[typeStart ..< typeStart + 4], encoding: .ascii) else {
                throw Failure.notPNG
            }

            if isAnimated {
                if type == "iCCP" { throw Failure.unremovableFromAnimation }
                if type == "eXIf", rotates(exifOrientationIn: bytes, at: offset + 8, length: payloadLength) {
                    throw Failure.unremovableFromAnimation
                }
            }

            // Bit 5 of the first letter is PNG's own ancillary flag: lowercase means
            // "a decoder may discard this", which is exactly the set under question.
            let isAncillary = bytes[typeStart] & 0x20 != 0
            if !isAncillary || allowedPNGAncillaryChunks.contains(type) {
                output.append(contentsOf: bytes[offset ..< offset + chunkLength])
            }
            offset += chunkLength
            if type == "IEND" { return output }
        }
        throw Failure.truncated
    }

    /// Ancillary chunks that describe the *picture* rather than its provenance, plus the three
    /// that carry an APNG's animation.
    private static let allowedPNGAncillaryChunks: Set<String> = [
        "cHRM", "gAMA", "sBIT", "sRGB", "bKGD", "hIST", "tRNS", "sPLT", "acTL", "fcTL", "fdAT",
    ]

    /// Whether a PNG carries an `acTL` chunk, which is what makes it an APNG.
    ///
    /// Read before the first `IDAT` by the specification, so this walk stops there rather than
    /// scanning megabytes of pixel data.
    public static func isAnimatedPNG(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 8
        while offset + 12 <= bytes.count {
            let payloadLength = Int(readUInt32BigEndian(bytes, at: offset))
            guard payloadLength >= 0, payloadLength <= bytes.count - offset - 12 else { return false }
            let type = String(bytes: bytes[offset + 4 ..< offset + 8], encoding: .ascii)
            if type == "acTL" { return true }
            if type == "IDAT" || type == "IEND" { return false }
            offset += payloadLength + 12
        }
        return false
    }
}
