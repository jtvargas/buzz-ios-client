import Foundation

/// The GIF half of ``ImageMetadataScrub`` — see that type for why.
extension ImageMetadataScrub {
    /// Keeps the frames, the graphic controls that time them and the loop extension, and drops
    /// every comment, plain-text and application block.
    public static func scrubGIF(_ data: Data) throws -> Data {
        var walk = try GIFWalk(data)
        try walk.run()
        return walk.result
    }
}

/// One pass over a GIF's blocks.
///
/// A struct rather than a loop with five cases in it, because the walk carries state that only
/// makes sense together: where it is, what it has decided to keep, and which graphic control is
/// still waiting to find out what block it belongs to.
///
/// # The retraction
///
/// A graphic control block describes the block that *follows* it. So a control preceding a plain
/// text block — which is dropped — has to be dropped with it, or the animation is retimed by a
/// frame that is no longer there. That is why segments are collected and nullable rather than
/// appended straight to the output.
private struct GIFWalk {
    private let bytes: [UInt8]
    private var offset: Int
    private var segments: [ArraySlice<UInt8>?]
    /// Indices in ``segments`` of graphic controls whose block has not been seen yet.
    private var pendingControls: [Int] = []

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 13,
              ImageMetadataScrub.matches(bytes, "GIF87a", at: 0)
              || ImageMetadataScrub.matches(bytes, "GIF89a", at: 0)
        else { throw ImageMetadataScrub.Failure.notGIF }

        var start = 13
        let packed = bytes[10]
        if packed & 0x80 != 0 {
            start += 3 << ((packed & 0x07) + 1)
            guard start <= bytes.count else { throw ImageMetadataScrub.Failure.truncated }
        }
        offset = start
        segments = [bytes[0 ..< start]]
    }

    var result: Data {
        var output = Data()
        for segment in segments { if let segment { output.append(contentsOf: segment) } }
        return output
    }

    mutating func run() throws {
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x2C: try takeImage()
            case 0x21: try takeExtension()
            case 0x3B:
                segments.append(bytes[offset ..< offset + 1])
                return
            default: throw ImageMetadataScrub.Failure.notGIF
            }
        }
        throw ImageMetadataScrub.Failure.truncated
    }

    /// A frame: its descriptor, any local colour table, and its compressed data.
    private mutating func takeImage() throws {
        let start = offset
        guard bytes.count - offset >= 10 else { throw ImageMetadataScrub.Failure.truncated }
        let packed = bytes[offset + 9]
        offset += 10
        if packed & 0x80 != 0 {
            offset += 3 << ((packed & 0x07) + 1)
            guard offset <= bytes.count else { throw ImageMetadataScrub.Failure.truncated }
        }
        guard offset < bytes.count else { throw ImageMetadataScrub.Failure.truncated }
        offset = try subBlocksEnd(from: offset + 1)
        segments.append(bytes[start ..< offset])
        // The control that preceded this frame belongs to it, and both are kept.
        pendingControls.removeAll()
    }

    private mutating func takeExtension() throws {
        let start = offset
        guard bytes.count - offset >= 2 else { throw ImageMetadataScrub.Failure.truncated }
        let label = bytes[offset + 1]
        offset += 2
        switch label {
        case 0xF9: try takeGraphicControl(from: start)
        case 0xFF: try takeApplicationBlock(from: start)
        case 0x01: try dropPlainText()
        default: offset = try subBlocksEnd(from: offset)
        }
    }

    private mutating func takeGraphicControl(from start: Int) throws {
        guard bytes.count - offset >= 6, bytes[offset] == 4, bytes[offset + 5] == 0 else {
            throw ImageMetadataScrub.Failure.notGIF
        }
        offset += 6
        segments.append(bytes[start ..< offset])
        pendingControls.append(segments.count - 1)
    }

    /// Only the loop extension survives; every other application block is provenance.
    private mutating func takeApplicationBlock(from start: Int) throws {
        guard bytes.count - offset >= 12, bytes[offset] == 11 else {
            throw ImageMetadataScrub.Failure.notGIF
        }
        let isLoop = ImageMetadataScrub.matches(bytes, "NETSCAPE2.0", at: offset + 1)
            || ImageMetadataScrub.matches(bytes, "ANIMEXTS1.0", at: offset + 1)
        let dataStart = offset + 12
        offset = try subBlocksEnd(from: dataStart)
        guard isLoop else { return }
        guard bytes.count - dataStart >= 5, bytes[dataStart] == 3, bytes[dataStart + 1] == 1 else {
            throw ImageMetadataScrub.Failure.notGIF
        }
        // The loop count and its own terminator, rebuilt rather than copied, so any trailing
        // sub-blocks the file smuggled in do not come with it.
        segments.append(bytes[start ..< dataStart + 4])
        segments.append([0][...])
    }

    /// Plain text goes, and so does whatever graphic control was timing it.
    private mutating func dropPlainText() throws {
        offset = try subBlocksEnd(from: offset)
        for index in pendingControls { segments[index] = nil }
        pendingControls.removeAll()
    }

    /// Walks a chain of length-prefixed sub-blocks to its terminating zero.
    private func subBlocksEnd(from start: Int) throws -> Int {
        var cursor = start
        while cursor < bytes.count {
            let length = Int(bytes[cursor])
            cursor += 1
            if length == 0 { return cursor }
            cursor += length
        }
        throw ImageMetadataScrub.Failure.truncated
    }
}
