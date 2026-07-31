@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Uploading against the **real relay**, because everything else about the upload is
/// asserted rather than tried.
///
/// The contract was read out of the mobile client and written into
/// ``MediaUploadTests`` — the kind, the tags, the base64 variant, the header names.
/// Every one of those assertions is this repository agreeing with itself. If the
/// relay disagrees, it answers `403` and names none of them: the authorisation is a
/// signed event in a header, so a wrong kind, a wrong encoding and a wrong tag all
/// look identical from the client side. This suite is the only thing that can tell
/// the difference.
///
/// It also pins the half the client does *not* compute. The relay measures the
/// picture — `dim`, `blurhash`, `thumb` — and the composer puts those straight into
/// the `imeta` tag it sends, so "the relay returns them" is load-bearing for a
/// message rendering at the right size on someone else's phone.
///
/// Disabled unless `BUZZKIT_INTEGRATION_URL` names a relay, like the rest of the live
/// suite. Run:
/// `BUZZKIT_INTEGRATION_URL=wss://homelab.tail4bc643.ts.net swift test -c release \
///   --package-path Packages/BuzzKit --filter LivePiMediaUpload`
@Suite("Live Pi media upload", .enabled(if: LiveRelay.enabled), .serialized, .timeLimit(.minutes(5)))
struct LivePiMediaUploadTests {
    static func client(signer: some EventSigner) -> MediaUploadClient {
        MediaUploadClient(
            transport: URLSessionHTTPTransport(),
            baseURL: LiveRelay.httpBase,
            signer: signer
        )
    }

    /// A distinct PNG per run, so a passing test can never be the relay handing back
    /// a blob some earlier run stored under the same hash.
    ///
    /// Hand-assembled rather than rendered: this package has no UIKit, and a PNG is
    /// a signature plus three chunks. One pixel of a colour taken from `seed` is
    /// enough — the relay is being asked whether it stores the bytes, not what is in
    /// them.
    static func uniquePNG(seed: UInt8) -> Data {
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + payload
            return be32(UInt32(payload.count)) + body + be32(crc32(body))
        }
        // 1×1, 8-bit RGB.
        let header = chunk("IHDR", be32(1) + be32(1) + [8, 2, 0, 0, 0])
        // One uncompressed zlib block holding a filter byte and three colour bytes.
        let raw: [UInt8] = [0, seed, 0x40, 0x80]
        let zlib: [UInt8] = [0x78, 0x01, 0x01, UInt8(raw.count), 0x00, UInt8(255 - raw.count), 0xFF]
            + raw + be32(adler32(raw))
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + header + chunk("IDAT", zlib) + chunk("IEND", []))
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    /// The whole contract in one request: the Blossom authorisation is accepted, the
    /// bytes are stored, and the answer carries what the client never computed.
    @Test("the relay accepts a Blossom-authorised upload and measures the picture")
    func uploadsAndIsMeasured() async throws {
        let signer = try InMemorySigner()
        let picture = Self.uniquePNG(seed: UInt8.random(in: 1 ... 254))

        let descriptor = try await Self.client(signer: signer).upload(
            data: picture,
            mimeType: "image/png"
        )

        // The bytes went up intact — the relay's hash is the one the client sent.
        #expect(descriptor.sha256 == MediaUploadClient.sha256Hex(picture))
        #expect(descriptor.size == picture.count)
        #expect(descriptor.type == "image/png")
        #expect(descriptor.url.hasPrefix("http"))
        #expect(descriptor.isImage)

        // The half the client does not compute, and the composer sends on trust.
        let dimensions = try #require(descriptor.dim)
        #expect(dimensions == "1x1")
        #expect(descriptor.blurhash?.isEmpty == false)

        // And what goes on the message parses back into renderable media, which is
        // the round trip the whole feature rests on.
        let media = MessageMedia.parse(tags: [descriptor.imetaTag()])
        #expect(media.count == 1)
        #expect(media.first?.kind == .image)
        #expect(media.first?.pixelSize == CGSize(width: 1, height: 1))
    }

    /// The uploaded blob is really there, at the URL the descriptor names — a
    /// descriptor whose URL 404s would still satisfy every assertion above.
    @Test("the picture can be fetched back from the URL the relay returned")
    func uploadedBlobIsRetrievable() async throws {
        let signer = try InMemorySigner()
        let picture = Self.uniquePNG(seed: UInt8.random(in: 1 ... 254))

        let descriptor = try await Self.client(signer: signer).upload(
            data: picture, mimeType: "image/png"
        )

        let url = try #require(URL(string: descriptor.url))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == picture)
    }

    /// HEIC is refused by the relay, which is the entire reason the picking side
    /// converts. If this ever passes, the conversion can go.
    @Test("HEIC is still not a type the relay stores")
    func heicIsStillRefused() async throws {
        #expect(!MediaUploadClient.supportedImageTypes.contains("image/heic"))
        #expect(!ImageByteFormat.heic.isStoredByRelay)
    }
}
