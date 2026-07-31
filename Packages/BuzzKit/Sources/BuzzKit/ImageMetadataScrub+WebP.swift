import Foundation

/// The WebP half of ``ImageMetadataScrub`` — see that type for why.
extension ImageMetadataScrub {
// MARK: - WebP

    /// Rebuilds the RIFF container from the chunks the relay allows, clearing the metadata flags
    /// in `VP8X` so the header does not advertise what has just been removed.
    public static func scrubWebP(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, matches(bytes, "RIFF", at: 0), matches(bytes, "WEBP", at: 8) else {
            throw Failure.notWebP
        }
        let declared = Int(readUInt32LittleEndian(bytes, at: 4))
        let end = declared + 8
        guard end >= 12, end <= bytes.count else { throw Failure.notWebP }

        var chunks = Data()
        var offset = 12
        while offset < end {
            guard end - offset >= 8 else { throw Failure.truncated }
            guard let type = String(bytes: bytes[offset ..< offset + 4], encoding: .ascii) else {
                throw Failure.notWebP
            }
            let payloadLength = Int(readUInt32LittleEndian(bytes, at: offset + 4))
            let payloadStart = offset + 8
            // Every RIFF chunk is padded to an even length.
            let chunkEnd = payloadStart + payloadLength + (payloadLength % 2)
            guard chunkEnd <= end else { throw Failure.notWebP }

            if type == "ICCP" { throw Failure.unremovableFromAnimation }
            if type == "EXIF", rotates(exifOrientationIn: bytes, at: payloadStart, length: payloadLength) {
                throw Failure.unremovableFromAnimation
            }

            if allowedWebPChunks.contains(type) {
                let payload = Array(bytes[payloadStart ..< payloadStart + payloadLength])
                if type == "VP8X" {
                    guard payloadLength > 0 else { throw Failure.notWebP }
                    // Bits for ICC, EXIF and XMP, cleared now that none of them are here.
                    var cleared = payload
                    cleared[0] &= ~UInt8(0x20 | 0x08 | 0x04)
                    appendWebPChunk(&chunks, type: type, payload: cleared)
                } else if type == "ANMF" {
                    appendWebPChunk(&chunks, type: type, payload: try scrubANMF(payload))
                } else {
                    appendWebPChunk(&chunks, type: type, payload: payload)
                }
            }
            offset = chunkEnd
        }

        var output = Data("RIFF".utf8)
        output.append(contentsOf: uint32LittleEndian(chunks.count + 4))
        output.append(contentsOf: Array("WEBP".utf8))
        output.append(chunks)
        return output
    }

    /// Chunks that carry the picture or its animation; everything else is provenance.
    private static let allowedWebPChunks: Set<String> = ["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF"]

    /// One animation frame: the 16-byte header, then only its image and alpha data.
    private static func scrubANMF(_ payload: [UInt8]) throws -> [UInt8] {
        let headerLength = 16
        guard payload.count >= headerLength else { throw Failure.notWebP }

        var output = Data(payload[0 ..< headerLength])
        var offset = headerLength
        var sawAlpha = false
        var sawImage = false
        while offset < payload.count {
            guard payload.count - offset >= 8 else { throw Failure.truncated }
            let length = Int(readUInt32LittleEndian(payload, at: offset + 4))
            let start = offset + 8
            let chunkEnd = start + length + (length % 2)
            guard chunkEnd <= payload.count else { throw Failure.notWebP }
            let body = Array(payload[start ..< start + length])

            if matches(payload, "ALPH", at: offset) {
                guard !sawAlpha, !sawImage else { throw Failure.notWebP }
                appendWebPChunk(&output, type: "ALPH", payload: body)
                sawAlpha = true
            } else if matches(payload, "VP8 ", at: offset) {
                guard !sawImage else { throw Failure.notWebP }
                appendWebPChunk(&output, type: "VP8 ", payload: body)
                sawImage = true
            } else if matches(payload, "VP8L", at: offset) {
                guard !sawAlpha, !sawImage else { throw Failure.notWebP }
                appendWebPChunk(&output, type: "VP8L", payload: body)
                sawImage = true
            }
            offset = chunkEnd
        }
        guard sawImage else { throw Failure.notWebP }
        return [UInt8](output)
    }

    private static func appendWebPChunk(_ output: inout Data, type: String, payload: [UInt8]) {
        output.append(contentsOf: Array(type.utf8))
        output.append(contentsOf: uint32LittleEndian(payload.count))
        output.append(contentsOf: payload)
        if payload.count % 2 == 1 { output.append(0) }
    }

    /// Whether a WebP animates — an `ANIM` chunk, or the animation bit set in `VP8X`.
    ///
    /// Asked before deciding how to clean it: an animated WebP has to be scrubbed structurally,
    /// where a still one is re-rendered (this client cannot encode WebP, so a still one comes
    /// out as a PNG).
    public static func isAnimatedWebP(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, matches(bytes, "RIFF", at: 0), matches(bytes, "WEBP", at: 8) else {
            return false
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let type = String(bytes: bytes[offset ..< offset + 4], encoding: .ascii)
            if type == "ANIM" || type == "ANMF" { return true }
            let payloadLength = Int(readUInt32LittleEndian(bytes, at: offset + 4))
            if type == "VP8X", payloadLength > 0, offset + 8 < bytes.count {
                // Bit 1 of the feature byte is the animation flag.
                if bytes[offset + 8] & 0x02 != 0 { return true }
            }
            offset += 8 + payloadLength + (payloadLength % 2)
        }
        return false
    }
}
