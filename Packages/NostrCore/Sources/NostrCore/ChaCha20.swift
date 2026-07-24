import Foundation

/// Raw ChaCha20 (RFC 8439), keystream only — the unauthenticated stream cipher
/// NIP-44 v2 layers its own HMAC over.
///
/// CryptoKit ships only the ChaCha20-Poly1305 AEAD, which fuses encryption and
/// authentication into one tag. NIP-44 instead wants the bare 20-round cipher
/// with a *separately* keyed HMAC-SHA256 computed over the nonce and ciphertext,
/// so the keystream is generated here by hand. ChaCha20 is a fixed
/// add-rotate-xor permutation with no data-dependent branching or memory access,
/// which is what makes hand-rolling it defensible: there is no secret-dependent
/// control flow for a timing side channel to observe. The output is checked
/// against RFC 8439's own block and encryption vectors, and end to end against
/// the NIP-44 suite.
enum ChaCha20 {
    /// The cipher's fixed block size in bytes.
    private static let blockSize = 64

    /// XORs `data` against the ChaCha20 keystream for `(key, nonce)`, with the
    /// block counter starting at zero, and returns the transformed bytes.
    ///
    /// The cipher is its own inverse, so this one call is both encryption and
    /// decryption. Each 64-byte keystream block is XORed straight into a
    /// preallocated output buffer, and the result is wrapped in `Data` exactly
    /// once at the very end: the read-state blobs and pairing payloads that flow
    /// through this path would otherwise pay for a reallocation on every byte.
    static func process(key: Data, nonce: Data, _ data: Data) -> Data {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")

        let input = [UInt8](data)
        guard !input.isEmpty else { return Data() }

        var output = [UInt8](repeating: 0, count: input.count)
        var state = initialState(key: key, nonce: nonce)
        var keystream = [UInt8](repeating: 0, count: blockSize)

        var counter: UInt32 = 0
        var offset = 0
        while offset < input.count {
            state[12] = counter
            permute(state, into: &keystream)
            let count = min(blockSize, input.count - offset)
            for index in 0 ..< count {
                output[offset + index] = input[offset + index] ^ keystream[index]
            }
            offset += blockSize
            counter &+= 1
        }
        return Data(output)
    }

    /// The 64-byte keystream block for a single counter value.
    ///
    /// A distinct entry point so the RFC 8439 §2.3.2 block-function vector can be
    /// asserted directly, independent of the streaming XOR path in ``process``.
    static func keystreamBlock(key: Data, nonce: Data, counter: UInt32) -> [UInt8] {
        var state = initialState(key: key, nonce: nonce)
        state[12] = counter
        var block = [UInt8](repeating: 0, count: blockSize)
        permute(state, into: &block)
        return block
    }

    /// Assembles the 16-word input state: the four ASCII constants, the eight key
    /// words, a zero counter placeholder at index 12, then the three nonce words.
    private static func initialState(key: Data, nonce: Data) -> [UInt32] {
        var state = [UInt32](repeating: 0, count: 16)
        // "expand 32-byte k" — the RFC's fixed constants.
        state[0] = 0x6170_7865
        state[1] = 0x3320_646E
        state[2] = 0x7962_2D32
        state[3] = 0x6B20_6574
        readLittleEndianWords(key, into: &state, at: 4) // eight key words: indices 4...11
        readLittleEndianWords(nonce, into: &state, at: 13) // three nonce words: indices 13...15
        return state
    }

    /// Runs the twenty-round permutation on a copy of `state` and serialises the
    /// result — each working word added back to the corresponding input word —
    /// as little-endian bytes into `block`.
    private static func permute(_ state: [UInt32], into block: inout [UInt8]) {
        var working = state

        // Ten column-then-diagonal double rounds make up ChaCha20's twenty rounds.
        for _ in 0 ..< 10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        for index in 0 ..< 16 {
            let word = working[index] &+ state[index]
            let base = index * 4
            block[base] = UInt8(truncatingIfNeeded: word)
            block[base + 1] = UInt8(truncatingIfNeeded: word >> 8)
            block[base + 2] = UInt8(truncatingIfNeeded: word >> 16)
            block[base + 3] = UInt8(truncatingIfNeeded: word >> 24)
        }
    }

    /// The ChaCha20 quarter round over four state words identified by position.
    private static func quarterRound(_ state: inout [UInt32], _ p0: Int, _ p1: Int, _ p2: Int, _ p3: Int) {
        state[p0] = state[p0] &+ state[p1]
        state[p3] = rotateLeft(state[p3] ^ state[p0], by: 16)
        state[p2] = state[p2] &+ state[p3]
        state[p1] = rotateLeft(state[p1] ^ state[p2], by: 12)
        state[p0] = state[p0] &+ state[p1]
        state[p3] = rotateLeft(state[p3] ^ state[p0], by: 8)
        state[p2] = state[p2] &+ state[p3]
        state[p1] = rotateLeft(state[p1] ^ state[p2], by: 7)
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    /// Reads `data` as consecutive little-endian 32-bit words into `state`,
    /// beginning at word index `start`. `data`'s length must be a multiple of 4.
    private static func readLittleEndianWords(_ data: Data, into state: inout [UInt32], at start: Int) {
        let bytes = [UInt8](data)
        var word = start
        var index = 0
        while index < bytes.count {
            state[word] = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            word += 1
            index += 4
        }
    }
}
