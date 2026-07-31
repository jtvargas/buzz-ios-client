@testable import BuzzKit
import Foundation
import Testing

/// What a picture's first bytes say it is.
///
/// # Why this is worth a suite
///
/// It decides one thing — whether the bytes go up untouched or get re-encoded
/// first — and both ways of getting it wrong are silent. Call a HEIC a JPEG and
/// the relay answers 415 for a photo the author can see on their own screen; call
/// a GIF unrecognised and it gets re-encoded into a single still frame, which
/// loses the animation and reports success.
@Suite("Image byte format")
struct ImageByteFormatTests {
    /// A header followed by enough filler that nothing here is reading past the end
    /// of a buffer that a real file would have more of.
    static func file(_ header: [UInt8]) -> Data {
        Data(header + [UInt8](repeating: 0, count: 64))
    }

    static func ascii(_ string: String) -> [UInt8] { Array(string.utf8) }

    /// An ISO base media header: a 4-byte box size, `ftyp`, a major brand, and
    /// however many compatible brands follow.
    static func isoBaseMedia(major: String, compatible: [String] = []) -> [UInt8] {
        [0, 0, 0, 0x20] + ascii("ftyp") + ascii(major) + compatible.flatMap(ascii)
    }

    @Test("A JPEG is recognised by its start-of-image marker")
    func jpeg() {
        #expect(ImageByteFormat.detect(Self.file([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
    }

    @Test("A PNG is recognised by its eight-byte signature")
    func png() {
        #expect(ImageByteFormat.detect(Self.file([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
    }

    @Test("Both GIF versions are recognised", arguments: ["GIF87a", "GIF89a"])
    func gif(_ signature: String) {
        #expect(ImageByteFormat.detect(Self.file(Self.ascii(signature))) == .gif)
    }

    /// `WEBP` sits at offset 8, after `RIFF` and a four-byte length — so a buffer
    /// that begins `RIFF` is not enough on its own.
    @Test("A WebP is recognised by RIFF plus its form type")
    func webp() {
        let header = Self.ascii("RIFF") + [0x24, 0x00, 0x00, 0x00] + Self.ascii("WEBP")
        #expect(ImageByteFormat.detect(Self.file(header)) == .webp)
    }

    @Test("A WAV is RIFF and is not a picture")
    func riffThatIsNotWebP() {
        let header = Self.ascii("RIFF") + [0x24, 0x00, 0x00, 0x00] + Self.ascii("WAVE")
        #expect(ImageByteFormat.detect(Self.file(header)) == nil)
    }

    @Test("Every HEIC brand is recognised as the major brand", arguments: [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1",
    ])
    func heicMajorBrand(_ brand: String) {
        #expect(ImageByteFormat.detect(Self.file(Self.isoBaseMedia(major: brand))) == .heic)
    }

    /// The reason the brand walk exists rather than a single read at offset 8: an
    /// iPhone writes HEICs whose major brand is unremarkable and whose recognisable
    /// brand is several entries into the compatible list.
    @Test("A HEIC is recognised by a compatible brand, not only the major one")
    func heicCompatibleBrand() {
        let header = Self.isoBaseMedia(major: "0000", compatible: ["mp41", "iso8", "heic"])
        #expect(ImageByteFormat.detect(Self.file(header)) == .heic)
    }

    /// The same container, and emphatically not a picture. Nothing in the walk may
    /// promote it, or an MP4 would be uploaded as `image/heic`.
    @Test("An MP4 shares the container and is not a HEIC")
    func mp4IsNotHEIC() {
        let header = Self.isoBaseMedia(major: "isom", compatible: ["iso2", "avc1", "mp41"])
        #expect(ImageByteFormat.detect(Self.file(header)) == nil)
    }

    @Test("Bytes that are not a picture are not recognised")
    func unrecognised() {
        #expect(ImageByteFormat.detect(Self.file(Self.ascii("%PDF-1.7"))) == nil)
    }

    /// Truncated input reads as unrecognised rather than trapping — the header
    /// reads are bounds-checked, and a short buffer is exactly what a cancelled
    /// load hands over.
    @Test("A header too short to classify is not a crash")
    func truncated() {
        #expect(ImageByteFormat.detect(Data()) == nil)
        #expect(ImageByteFormat.detect(Data([0xFF, 0xD8])) == nil)
        #expect(ImageByteFormat.detect(Data(Self.ascii("RIFF"))) == nil)
        #expect(ImageByteFormat.detect(Data([0, 0, 0, 0x20] + Self.ascii("ftyp"))) == nil)
    }

    /// A `Data` slice does not start at index 0, and every offset here is from the
    /// start of the file. This is the read that would silently classify everything
    /// as unrecognised if the buffer were indexed directly.
    @Test("A slice of a larger buffer is classified by its own first bytes")
    func sliceOfALargerBuffer() {
        let padded = Data([0xAA, 0xBB, 0xCC]) + Self.file([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(ImageByteFormat.detect(padded.dropFirst(3)) == .jpeg)
    }

    /// The transcode decision. HEIC is the only recognised format that has to be
    /// re-encoded, and the four the relay stores must pass through untouched — a
    /// GIF or an animated WebP put through a re-encode comes out as one still frame.
    @Test("Only HEIC needs converting before it is uploaded")
    func transcodeDecision() {
        #expect(ImageByteFormat.jpeg.isStoredByRelay)
        #expect(ImageByteFormat.png.isStoredByRelay)
        #expect(ImageByteFormat.gif.isStoredByRelay)
        #expect(ImageByteFormat.webp.isStoredByRelay)
        #expect(!ImageByteFormat.heic.isStoredByRelay)
    }

    /// Every case's MIME type is one the relay names, or is the one deliberate
    /// exception. Guards against a case being added here with a type the upload
    /// client would refuse before a request is ever made.
    @Test("Every format's MIME type is either stored or is HEIC")
    func mimeTypesAreAccountedFor() {
        for format in ImageByteFormat.allCases {
            #expect(
                format.isStoredByRelay || format == .heic,
                "\(format.mimeType) is neither stored by the relay nor the HEIC exception"
            )
        }
    }
}
