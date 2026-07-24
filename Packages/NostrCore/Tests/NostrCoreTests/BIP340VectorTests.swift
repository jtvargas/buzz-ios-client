import Foundation
@testable import NostrCore
import P256K
import Testing

/// The full BIP-340 reference vector suite (bitcoin/bips `test-vectors.csv`),
/// vendored verbatim and run in both directions.
///
/// Verification runs every row through ``verifySchnorrSignature`` — the exact
/// entry point event-signature checks use. Signing runs the deterministic rows
/// through P256K with the vector's own auxiliary randomness injected, which is
/// the only way to reproduce a BIP-340 signature byte for byte; production
/// signing always draws fresh randomness, so this injection lives in tests only.
@Suite("BIP-340 reference vectors")
struct BIP340VectorTests {
    /// One row of the CSV. Hex fields are lowercased to match this package's
    /// strict-lowercase hex coding; `secretKey` and `auxRand` are empty on the
    /// verify-only rows.
    struct Row {
        let index: Int
        let secretKey: String
        let publicKey: String
        let auxRand: String
        let message: String
        let signature: String
        let verifies: Bool
        let comment: String
    }

    static func load() throws -> [Row] {
        let url = try #require(
            Bundle.module.url(forResource: "bip340-test-vectors", withExtension: "csv"),
            "the BIP-340 vector resource must be bundled with the test target"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)

        var rows: [Row] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let index = Int(fields[0]) else { continue }
            rows.append(Row(
                index: index,
                secretKey: fields[1].lowercased(),
                publicKey: fields[2].lowercased(),
                auxRand: fields[3].lowercased(),
                message: fields[4].lowercased(),
                signature: fields[5].lowercased(),
                verifies: fields[6].uppercased() == "TRUE",
                comment: fields.count >= 8 ? fields[7] : ""
            ))
        }
        return rows
    }

    @Test("every row verifies to its expected result")
    func verificationMatchesEveryRow() throws {
        let rows = try Self.load()
        #expect(rows.count == 19)

        for row in rows {
            let signature = try #require(Data(hexString: row.signature), "row \(row.index) signature")
            let publicKey = try #require(Data(hexString: row.publicKey), "row \(row.index) public key")
            let message = try #require(Data(hexString: row.message), "row \(row.index) message")
            let result = verifySchnorrSignature(signature: signature, message: message, publicKeyXOnly: publicKey)

            if message.count == 32 {
                #expect(result == row.verifies, "row \(row.index): \(row.comment)")
            } else {
                // The Nostr-scoped verifier accepts only a 32-byte digest (an event
                // id), so BIP-340's variable-length-message rows (15-18) are rejected
                // by contract, independent of their cryptographic validity.
                #expect(result == false, "row \(row.index): \(message.count)-byte message must be rejected")
            }
        }
    }

    @Test("a listed secret key derives its listed public key")
    func publicKeyDerivation() throws {
        for row in try Self.load() where !row.secretKey.isEmpty {
            let key = try PrivateKey(hex: row.secretKey)
            #expect(key.publicKey.hex == row.publicKey, "row \(row.index)")
        }
    }

    @Test("signing rows 0-3 reproduces the exact vector signature")
    func signDirectionExactMatch() throws {
        for row in try Self.load() where row.index <= 3 {
            #expect(!row.secretKey.isEmpty, "row \(row.index) must carry a secret key")

            let secret = try #require(Data(hexString: row.secretKey))
            let signingKey = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            var message = try Array(#require(Data(hexString: row.message)))
            var auxiliary = try Array(#require(Data(hexString: row.auxRand)))

            let signature = try auxiliary.withUnsafeMutableBytes { buffer in
                try signingKey.signature(message: &message, auxiliaryRand: buffer.baseAddress, strict: true)
            }

            // Exact byte match against the vector, and the result verifies through
            // our own public entry point.
            #expect(signature.dataRepresentation.hexString == row.signature, "row \(row.index)")
            let publicKey = try #require(Data(hexString: row.publicKey))
            #expect(verifySchnorrSignature(
                signature: signature.dataRepresentation,
                message: Data(message),
                publicKeyXOnly: publicKey
            ), "row \(row.index) must verify")
        }
    }
}
