import BuzzKit
import Foundation
@testable import Hive
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A ``MediaUploading`` double a test drives by hand.
///
/// Uploads do not complete on their own — each one parks until the test releases
/// it. That is what makes "send is refused while a picture is still going up" and
/// "removing a tile mid-upload does not bring it back" assertable at all: both are
/// about the window *during* an upload, which a double that answers immediately
/// never opens.
actor StubUploader: MediaUploading {
    /// What a released upload answers with.
    enum Answer: Sendable {
        case success
        case failure(MediaUploadError)
    }

    struct Request: Sendable, Equatable {
        let mimeType: String
        let byteCount: Int
        let filename: String?
    }

    private(set) var requests: [Request] = []
    /// Uploads that have arrived and not yet been answered.
    private var parked: [CheckedContinuation<Answer, Never>] = []
    /// How many are parked at this instant — the assertion behind the concurrency cap.
    private(set) var peakConcurrent = 0

    func upload(data: Data, mimeType: String, filename: String?) async throws -> BlobDescriptor {
        requests.append(Request(mimeType: mimeType, byteCount: data.count, filename: filename))
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            parked.append(continuation)
            peakConcurrent = max(peakConcurrent, parked.count)
        }
        switch answer {
        case .success:
            // Keyed by the pick's own name, not by arrival order: three uploads run
            // at once, so which request reaches this actor first is a race, and an
            // assertion about *which* picture ended up where must not depend on it.
            return Self.descriptor(key: filename ?? "\(requests.count - 1)", mimeType: mimeType, size: data.count)
        case let .failure(error):
            throw error
        }
    }

    /// How many uploads are waiting to be answered.
    var parkedCount: Int { parked.count }

    /// Lets every parked upload through with the same answer.
    func releaseAll(_ answer: Answer = .success) {
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume(returning: answer) }
    }

    /// Lets exactly one through, oldest first.
    func releaseOne(_ answer: Answer = .success) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(returning: answer)
    }

    /// A descriptor distinguishable by key, so a test can assert *which* picture
    /// ended up in a message and in what order.
    static func descriptor(key: String, mimeType: String, size: Int) -> BlobDescriptor {
        BlobDescriptor(
            url: "https://relay.example/media/\(key).jpg",
            sha256: String(repeating: "a", count: 8) + key,
            size: size,
            type: mimeType,
            uploaded: 1_700_000_000,
            dim: "800x600",
            blurhash: "L00000"
        )
    }
}

/// A pick that hands over bytes the test chose.
struct StubPickedItem: ComposerPickedItem {
    let data: Data
    var suggestedFilename: String?
    /// Fails the *load*, before anything reaches the uploader — what a picker
    /// returning an item it cannot produce bytes for looks like.
    var failsToLoad = false
    /// Never answers at all — an iCloud-backed photo whose download does not arrive.
    ///
    /// This is the shape of the owner's report, and it is the one a stub that merely *fails*
    /// cannot express: the defect was never an error, it was the absence of one.
    var neverReturns = false

    func loadData() async throws -> Data {
        if failsToLoad { throw ComposerAttachmentError.emptyPick }
        if neverReturns {
            // Long enough to be indistinguishable from for ever at test speed, and
            // cancellable so the deadline's own cleanup is exercised.
            try await Task.sleep(for: .seconds(600))
        }
        return data
    }
}

/// Real pictures for the tests, because the pipeline decodes what it is given:
/// ``ComposerImagePreparation`` opens the bytes with ImageIO both to make a
/// thumbnail and to decide whether they need converting, so a fixture of arbitrary
/// bytes would fail every test for the same uninteresting reason.
enum TestPicture {
    /// A PNG — a format the relay stores, so it goes up untouched.
    static func png(width: Int = 32, height: Int = 24) -> Data {
        rendered(width: width, height: height).pngData()!
    }

    /// A TIFF, which the relay does *not* store — the same branch a HEIC from the
    /// camera takes, without needing a HEIC encoder on the machine running this.
    ///
    /// - Parameter orientation: written into the file's own metadata, exactly as a
    ///   camera writes the rotation of a photo shot in portrait.
    static func tiff(width: Int = 40, height: Int = 20, orientation: Int? = nil) -> Data? {
        guard let cgImage = rendered(width: width, height: height).cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.tiff.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = orientation.map {
            [kCGImagePropertyOrientation: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A PNG carrying a text chunk — a stored format that still has something on it the
    /// relay refuses, which is the case that used to be passed straight through.
    static func pngWithMetadata(width: Int = 32, height: Int = 24) -> Data {
        let clean = png(width: width, height: height)
        let bytes = [UInt8](clean)
        // Past the signature and IHDR.
        var offset = 8
        let ihdrLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        offset += ihdrLength + 12

        var output = Data(bytes[0 ..< offset])
        output.append(pngChunk(type: "tEXt", payload: Array("Comment\0where this was taken".utf8)))
        output.append(contentsOf: bytes[offset...])
        return output
    }

    /// What a camera writes: EXIF including GPS, and a Display P3 colour profile. Both are
    /// refused by the relay, and the first is the reason this is a privacy question too.
    static func photoJPEG(width: Int = 40, height: Int = 24) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        for column in 0 ..< width {
            context.setFillColor(red: CGFloat(column) / CGFloat(width), green: 0.3, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: column, y: 0, width: 1, height: height))
        }
        guard let image = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:31 13:37:00",
                kCGImagePropertyExifUserComment: "long enough to be worth removing",
            ] as CFDictionary,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 18.4861,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 69.9312,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as CFDictionary,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Two frames and a comment, assembled by hand — nothing on this platform encodes an
    /// animated GIF, and the assertion is that the frames survive.
    static func animatedGIF() -> Data {
        var output = Data("GIF89a".utf8)
        output.append(contentsOf: [2, 0, 2, 0, 0x80, 0, 0])
        output.append(contentsOf: [0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(contentsOf: [0x21, 0xFE, 5])
        output.append(contentsOf: Array("hello".utf8))
        output.append(0)
        for _ in 0 ..< 2 {
            output.append(contentsOf: [0x21, 0xF9, 4, 0x00, 10, 0, 0, 0])
            output.append(contentsOf: [0x2C, 0, 0, 0, 0, 2, 0, 2, 0, 0x00])
            output.append(contentsOf: [0x02, 0x02, 0x4C, 0x01, 0x00])
        }
        output.append(0x3B)
        return output
    }

    /// How many frames a GIF holds, read through ImageIO rather than by counting bytes — a
    /// flattened animation is exactly what this has to be able to see.
    static func gifFrameCount(in data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// Every JPEG marker in the header, so a test can say "no EXIF" rather than "it uploaded".
    static func jpegMarkers(in data: Data) -> Set<UInt8> {
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

    /// The bytes one colour comes out as when written in `space` — the reference the colour
    /// conversion is asserted against.
    static func pixel(_ components: [CGFloat], in space: CFString) -> [UInt8]? {
        guard let colourSpace = CGColorSpace(name: space),
              let context = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: colourSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return [bytes[0], bytes[1], bytes[2]]
    }

    /// A picture filled with one colour, written in `space`.
    static func flooded(_ components: [CGFloat], in space: CFString, size: Int = 32) -> Data? {
        guard let colourSpace = CGColorSpace(name: space),
              let context = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colourSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// One pixel from the middle of an encoded picture, read back through sRGB — which is how
    /// a viewer with no profile to go on will read it.
    static func centrePixel(of data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        // Drawing the whole picture into one pixel averages it, which for a flat fill is that
        // fill and for anything else is not a claim this helper makes.
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let raw = context.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: 4)
        return [bytes[0], bytes[1], bytes[2]]
    }

    /// How far apart two colours are, as the largest difference in any channel.
    static func distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// A PNG chunk with a correct CRC — an incorrect one would be refused by the decoder
    /// rather than by the code under test.
    private static func pngChunk(type: String, payload: [UInt8]) -> Data {
        let typeBytes = Array(type.utf8)
        var output = Data()
        let length = UInt32(payload.count)
        output.append(contentsOf: [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ])
        output.append(contentsOf: typeBytes)
        output.append(contentsOf: payload)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typeBytes + payload {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        crc ^= 0xFFFF_FFFF
        output.append(contentsOf: [
            UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF),
        ])
        return output
    }

    private static func rendered(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
