import Foundation

// Animations to scrub, assembled by hand.
//
// Nothing on this platform encodes an APNG or an animated WebP, and the scrub under test must
// not decode them — so proving it left an animation's structure alone needs bytes whose
// structure is known because it was written here.
// MARK: - GIF

enum GIFBytes {
    /// Two frames, two graphic controls, a loop extension and a comment.
    static func animated(withComment: Bool) throws -> Data {
        var output = Data("GIF89a".utf8)
        // 2x2, global colour table of two entries.
        output.append(contentsOf: [2, 0, 2, 0, 0x80, 0, 0])
        output.append(contentsOf: [0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF])
        // NETSCAPE2.0 loop, forever.
        output.append(contentsOf: [0x21, 0xFF, 11])
        output.append(contentsOf: Array("NETSCAPE2.0".utf8))
        output.append(contentsOf: [3, 1, 0, 0, 0])
        if withComment {
            output.append(contentsOf: [0x21, 0xFE, 17])
            output.append(contentsOf: Array("provenance again\n".utf8))
            output.append(0)
        }
        for _ in 0 ..< 2 {
            // Graphic control: 10ms, no transparency.
            output.append(contentsOf: [0x21, 0xF9, 4, 0x00, 10, 0, 0, 0])
            // Image descriptor at 0,0, 2x2, no local table.
            output.append(contentsOf: [0x2C, 0, 0, 0, 0, 2, 0, 2, 0, 0x00])
            // Minimum LZW code size, one sub-block, terminator.
            output.append(contentsOf: [0x02, 0x02, 0x4C, 0x01, 0x00])
        }
        output.append(0x3B)
        return output
    }

    static func hasComment(_ data: Data) -> Bool {
        contains(data, marker: [0x21, 0xFE])
    }

    static func hasNetscapeLoop(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let needle = Array("NETSCAPE2.0".utf8)
        guard bytes.count >= needle.count else { return false }
        for start in 0 ... (bytes.count - needle.count) where Array(bytes[start ..< start + needle.count]) == needle {
            return true
        }
        return false
    }

    static func imageDescriptorCount(_ data: Data) -> Int {
        // Counted structurally by walking, because 0x2C occurs in colour tables too.
        walk(data).filter { $0 == .image }.count
    }

    static func graphicControlCount(_ data: Data) -> Int {
        walk(data).filter { $0 == .graphicControl }.count
    }

    private enum Block: Equatable { case image, graphicControl, other }

    private static func walk(_ data: Data) -> [Block] {
        let bytes = [UInt8](data)
        var blocks: [Block] = []
        var offset = 13
        if bytes.count > 10, bytes[10] & 0x80 != 0 {
            offset += 3 << ((bytes[10] & 0x07) + 1)
        }
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x2C:
                blocks.append(.image)
                guard bytes.count - offset >= 10 else { return blocks }
                let packed = bytes[offset + 9]
                offset += 10
                if packed & 0x80 != 0 { offset += 3 << ((packed & 0x07) + 1) }
                offset = subBlocksEnd(bytes, from: offset + 1)
            case 0x21:
                guard bytes.count - offset >= 2 else { return blocks }
                let label = bytes[offset + 1]
                blocks.append(label == 0xF9 ? .graphicControl : .other)
                offset += 2
                if label == 0xF9 {
                    offset += 6
                } else if label == 0xFF {
                    offset = subBlocksEnd(bytes, from: offset + 12)
                } else {
                    offset = subBlocksEnd(bytes, from: offset)
                }
            default:
                return blocks
            }
        }
        return blocks
    }

    private static func subBlocksEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var offset = start
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 { return offset }
            offset += length
        }
        return offset
    }

    private static func contains(_ data: Data, marker: [UInt8]) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= marker.count else { return false }
        for start in 0 ... (bytes.count - marker.count) where Array(bytes[start ..< start + marker.count]) == marker {
            return true
        }
        return false
    }
}

// MARK: - WebP

enum WebPBytes {
    static func still() -> Data {
        container(chunks: [("VP8L", [0x2F, 0x00, 0x00, 0x00, 0x00])])
    }

    /// An extended WebP that animates, with the metadata flags set in `VP8X` the way a file
    /// carrying EXIF or a profile really would.
    static func animated(withEXIF: Bool = false, withICCP: Bool = false) -> Data {
        var features: UInt8 = 0x02 // animation
        if withEXIF { features |= 0x08 }
        if withICCP { features |= 0x20 }
        var chunks: [(String, [UInt8])] = [
            ("VP8X", [features, 0, 0, 0] + [31, 0, 0] + [23, 0, 0]),
            ("ANIM", [0, 0, 0, 0, 0, 0]),
            ("ANMF", anmf()),
        ]
        if withICCP { chunks.append(("ICCP", Array(repeating: 0x11, count: 8))) }
        if withEXIF { chunks.append(("EXIF", Array("Exif\0\0II*\0\u{08}\0\0\0".utf8))) }
        return container(chunks: chunks)
    }

    /// One animation frame: the 16-byte header, then a sub-chunk of image data, plus an
    /// unknown sub-chunk that has no business surviving.
    private static func anmf() -> [UInt8] {
        var payload: [UInt8] = Array(repeating: 0, count: 16)
        payload.append(contentsOf: Array("VP8L".utf8))
        payload.append(contentsOf: [5, 0, 0, 0])
        payload.append(contentsOf: [0x2F, 0x00, 0x00, 0x00, 0x00])
        payload.append(0) // padding to an even length
        payload.append(contentsOf: Array("JUNK".utf8))
        payload.append(contentsOf: [2, 0, 0, 0])
        payload.append(contentsOf: [0xAA, 0xBB])
        return payload
    }

    static func chunkTypes(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var types: [String] = []
        var offset = 12
        while offset + 8 <= bytes.count {
            guard let type = String(bytes: bytes[offset ..< offset + 4], encoding: .ascii) else { break }
            types.append(type)
            let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            offset += 8 + length + (length % 2)
        }
        return types
    }

    static func vp8xFeatureByte(in data: Data) -> UInt8? {
        let bytes = [UInt8](data)
        var offset = 12
        while offset + 8 <= bytes.count {
            let type = String(bytes: bytes[offset ..< offset + 4], encoding: .ascii)
            let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            if type == "VP8X", offset + 8 < bytes.count { return bytes[offset + 8] }
            offset += 8 + length + (length % 2)
        }
        return nil
    }

    private static func container(chunks: [(String, [UInt8])]) -> Data {
        var body = Data()
        for (type, payload) in chunks {
            body.append(contentsOf: Array(type.utf8))
            let length = UInt32(payload.count)
            body.append(contentsOf: [
                UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF),
            ])
            body.append(contentsOf: payload)
            if payload.count % 2 == 1 { body.append(0) }
        }
        var output = Data("RIFF".utf8)
        let total = UInt32(body.count + 4)
        output.append(contentsOf: [
            UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
            UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF),
        ])
        output.append(contentsOf: Array("WEBP".utf8))
        output.append(body)
        return output
    }
}

enum FixtureFailure: Error { case couldNotEncode }
