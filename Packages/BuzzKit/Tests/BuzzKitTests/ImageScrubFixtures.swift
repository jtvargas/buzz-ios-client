import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures to scrub, and the readers that check what came off them.
///
/// Two kinds of fixture here, deliberately:
///
/// - **Encoded by ImageIO** (`ImageFixture`) — a JPEG that really does carry EXIF, GPS and a
///   Display P3 profile the way a camera writes them, so the scrub is tested against the
///   system's own output rather than against a hand-made file that might be easier.
/// - **Assembled by hand** (`PNGChunks`, `GIFBytes`, `WebPBytes`) — animations, because
///   nothing on this platform encodes an APNG or an animated WebP, and a scrub that must not
///   decode them needs bytes with a known structure to prove it left that structure alone.
enum ImageFixture {
    /// A JPEG, optionally carrying what a photograph carries.
    ///
    /// - Parameters:
    ///   - exif: writes an EXIF dictionary including GPS coordinates — the tags that make
    ///     this a privacy question and not only an upload one.
    ///   - wideGamut: renders in Display P3, which is what makes the encoder attach a colour
    ///     profile (`APP2`). That segment is the one the *fix* used to create by itself.
    static func jpeg(
        exif: Bool = false,
        wideGamut: Bool = false,
        width: Int = 32,
        height: Int = 24
    ) -> Data? {
        guard let image = cgImage(width: width, height: height, wideGamut: wideGamut) else { return nil }
        var properties: [CFString: Any] = [:]
        if exif {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: "a comment long enough to be worth removing",
                kCGImagePropertyExifDateTimeOriginal: "2026:07:31 13:37:00",
            ] as CFDictionary
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 18.4861,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 69.9312,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as CFDictionary
        }
        return encode(image, as: UTType.jpeg, properties: properties)
    }

    /// A PNG, optionally carrying a text chunk.
    static func png(text: Bool = false, width: Int = 32, height: Int = 24) -> Data? {
        guard let image = cgImage(width: width, height: height, wideGamut: false) else { return nil }
        var properties: [CFString: Any] = [:]
        if text {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGDescription: "provenance nobody asked to publish",
            ] as CFDictionary
        }
        guard let encoded = encode(image, as: UTType.png, properties: properties) else { return nil }
        // ImageIO may decline to write the description on some systems; the chunk is what the
        // test is about, so it is added directly when that happens.
        if text, !PNGChunks.types(in: encoded).contains("tEXt") {
            return PNGChunks.inserting(
                type: "tEXt",
                payload: Array("Comment\0provenance nobody asked to publish".utf8),
                into: encoded
            )
        }
        return encoded
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func cgImage(width: Int, height: Int, wideGamut: Bool) -> CGImage? {
        let space = wideGamut
            ? CGColorSpace(name: CGColorSpace.displayP3)
            : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        // A gradient rather than a flat fill: a flat colour compresses to almost nothing and
        // makes a size comparison meaningless.
        for column in 0 ..< width {
            context.setFillColor(
                red: CGFloat(column) / CGFloat(width), green: 0.4, blue: 0.8, alpha: 1
            )
            context.fill(CGRect(x: column, y: 0, width: 1, height: height))
        }
        return context.makeImage()
    }
}

// MARK: - JPEG

enum JPEGSegments {
    /// Every marker byte in the file, up to the start of the scan.
    ///
    /// The scan is skipped because entropy-coded data is full of bytes that look like markers
    /// and are not; everything this asserts about lives in the header anyway.
    static func markers(in data: Data) -> Set<UInt8> {
        let bytes = [UInt8](data)
        var found: Set<UInt8> = []
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { break }
            let marker = bytes[offset + 1]
            found.insert(marker)
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2 else { break }
            offset += 2 + length
        }
        return found
    }

    /// Puts a segment in immediately after the `SOI`, which is where a real one would sit.
    static func inserting(marker: UInt8, payload: [UInt8], into data: Data) throws -> Data {
        var output = Data([0xFF, 0xD8])
        let length = payload.count + 2
        output.append(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)])
        output.append(contentsOf: payload)
        output.append(data.dropFirst(2))
        return output
    }
}

// MARK: - PNG

enum PNGChunks {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func types(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var types: [String] = []
        var offset = signature.count
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 0, length <= bytes.count - offset - 12 else { break }
            if let type = String(bytes: bytes[offset + 4 ..< offset + 8], encoding: .ascii) {
                types.append(type)
                if type == "IEND" { break }
            }
            offset += length + 12
        }
        return types
    }

    /// Puts a chunk in after `IHDR`, with a correct CRC — an incorrect one would be rejected
    /// by the decoder rather than by the scrub, which would test the wrong thing.
    static func inserting(type: String, payload: [UInt8], into data: Data) -> Data {
        let bytes = [UInt8](data)
        var offset = signature.count
        // Past IHDR.
        let ihdrLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        offset += ihdrLength + 12

        var output = Data(bytes[0 ..< offset])
        output.append(chunk(type: type, payload: payload))
        output.append(contentsOf: bytes[offset...])
        return output
    }

    static func chunk(type: String, payload: [UInt8]) -> Data {
        let typeBytes = Array(type.utf8)
        var output = Data()
        let length = UInt32(payload.count)
        output.append(contentsOf: [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ])
        output.append(contentsOf: typeBytes)
        output.append(contentsOf: payload)
        let crc = crc32(typeBytes + payload)
        output.append(contentsOf: [
            UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF),
        ])
        return output
    }

    /// A PNG carrying the three chunks that make it animate, plus a text chunk to remove and
    /// optionally the colour profile that makes it unscrubbable.
    ///
    /// Assembled rather than encoded: nothing on this platform writes an APNG, and the point
    /// is to prove the scrub leaves an animation's structure alone without decoding it.
    static func synthesisedAPNG(includeICCP: Bool = false) throws -> Data {
        guard let still = ImageFixture.png() else {
            throw FixtureFailure.couldNotEncode
        }
        let bytes = [UInt8](still)
        var offset = signature.count
        let ihdrLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        let afterIHDR = offset + ihdrLength + 12
        offset = afterIHDR

        var output = Data(bytes[0 ..< afterIHDR])
        // Two frames, one loop.
        output.append(chunk(type: "acTL", payload: [0, 0, 0, 2, 0, 0, 0, 1]))
        if includeICCP {
            output.append(chunk(type: "iCCP", payload: Array("p3\0\0".utf8) + [0x78, 0x9C, 0x01]))
        }
        output.append(chunk(type: "tEXt", payload: Array("Comment\0remove me".utf8)))
        // Frame control for the first frame: sequence 0, the full 32x24, no offset.
        output.append(chunk(type: "fcTL", payload: frameControl(sequence: 0)))
        // The original IDAT and everything after it, minus the trailer, then a second frame.
        var tail = Data()
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(bytes: bytes[offset + 4 ..< offset + 8], encoding: .ascii) ?? ""
            if type == "IEND" { break }
            tail.append(contentsOf: bytes[offset ..< offset + length + 12])
            offset += length + 12
        }
        output.append(tail)
        output.append(chunk(type: "fcTL", payload: frameControl(sequence: 1)))
        let frameData: [UInt8] = [0, 0, 0, 2, 0x78, 0x9C, 0x03, 0x00]
        output.append(chunk(type: "fdAT", payload: frameData))
        output.append(chunk(type: "IEND", payload: []))
        return output
    }

    /// One `fcTL` payload: sequence number, the full 32×24 frame at the origin, 10/100s delay,
    /// no disposal or blend. Built in steps because the literal-concatenated form defeats the
    /// type checker.
    private static func frameControl(sequence: UInt8) -> [UInt8] {
        var payload: [UInt8] = [0, 0, 0, sequence]
        payload.append(contentsOf: [0, 0, 0, 32]) // width
        payload.append(contentsOf: [0, 0, 0, 24]) // height
        payload.append(contentsOf: [0, 0, 0, 0]) // x offset
        payload.append(contentsOf: [0, 0, 0, 0]) // y offset
        payload.append(contentsOf: [0, 10]) // delay numerator
        payload.append(contentsOf: [0, 100]) // delay denominator
        payload.append(contentsOf: [0, 0]) // dispose, blend
        return payload
    }

    /// PNG's own CRC-32, computed rather than tabled — this runs a handful of times.
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
