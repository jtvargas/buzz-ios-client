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

    func loadData() async throws -> Data {
        if failsToLoad { throw ComposerAttachmentError.emptyPick }
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
