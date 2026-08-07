@testable import BuzzKit
import CryptoKit
import Foundation
import NostrCore
import Testing

/// What the relay is told when a picture is uploaded.
///
/// # Why this is asserted rather than tried
///
/// Every field here is a contract with a server this test cannot reach, read out
/// of the mobile client that already satisfies it. A wrong one does not fail
/// loudly — it comes back as a 401 or a 403 with nothing naming which of the
/// three headers was wrong, and the two encodings involved look identical in a
/// debugger. So the header is taken apart here: the kind, the tags, and the
/// base64 variant.
@Suite("Media upload")
struct MediaUploadTests {
    /// Records what it was asked to `PUT` and answers with whatever it was given.
    actor RecordingTransport: MediaUploadTransport {
        private(set) var requests: [RecordedUpload] = []
        private var answers: [(Data, Int)]

        init(answers: [(Data, Int)]) {
            self.answers = answers
        }

        func put(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
            requests.append(RecordedUpload(url: url, headers: headers, body: body))
            return answers.isEmpty ? (Data(), 500) : answers.removeFirst()
        }
    }

    static let descriptorJSON = """
    {"url":"https://relay.example/media/abc.jpg","sha256":"abc","size":12,
     "type":"image/jpeg","uploaded":1700000000,"dim":"800x600",
     "blurhash":"L00000","thumb":"https://relay.example/media/abc.thumb.jpg"}
    """

    static func client(
        transport: RecordingTransport,
        base: String = "https://relay.example"
    ) throws -> MediaUploadClient {
        try MediaUploadClient(
            transport: transport,
            baseURL: #require(URL(string: base)),
            signer: InMemorySigner(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    // MARK: - The header

    @Test("the authorisation is a kind 24242 event tagged for this exact upload")
    func authorizationEventShape() async throws {
        let transport = RecordingTransport(answers: [(Data(Self.descriptorJSON.utf8), 200)])
        _ = try await Self.client(transport: transport)
            .upload(data: Data("hello".utf8), mimeType: "image/jpeg")

        let request = try #require(await transport.requests.first)
        let header = try #require(request.headers["Authorization"])
        #expect(header.hasPrefix("Nostr "))

        let event = try Self.decodeAuthorizationEvent(header)
        #expect(event.kind == EventKind(rawValue: 24242))
        #expect(event.tags.contains(["t", "upload"]))
        // The hash is of the *body*, and the same value is repeated in its own
        // header — a mismatch between the two is a rejection with no diagnosis.
        let digest = MediaUploadClient.sha256Hex(Data("hello".utf8))
        #expect(event.tags.contains(["x", digest]))
        #expect(request.headers["X-SHA-256"] == digest)
        #expect(request.headers["Content-Type"] == "image/jpeg")
        // Ten minutes, matching the mobile client.
        #expect(event.tags.contains(["expiration", "1700000600"]))
        #expect(event.tags.contains(["server", "relay.example"]))
    }

    /// The encoding, alone, because it is the one that looks right when it is not.
    ///
    /// `NIP98` produces `Nostr <standard base64>` for a different kind entirely.
    /// Blossom wants **base64url, unpadded**: `+`→`-`, `/`→`_`, no `=`.
    @Test("the header is base64url without padding, not standard base64")
    func headerEncodingIsBase64URL() async throws {
        let transport = RecordingTransport(answers: [(Data(Self.descriptorJSON.utf8), 200)])
        _ = try await Self.client(transport: transport)
            .upload(data: Data("hello".utf8), mimeType: "image/jpeg")
        let header = try #require(await transport.requests.first?.headers["Authorization"])
        let encoded = String(header.dropFirst("Nostr ".count))

        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        // And it still decodes to the event, so the substitution is reversible
        // rather than merely absent.
        #expect(throws: Never.self) { try Self.decodeAuthorizationEvent(header) }
    }

    @Test(
        "the server authority drops a default port and keeps a real one",
        arguments: [
            ("https://relay.example", "relay.example"),
            ("https://relay.example:443", "relay.example"),
            ("http://relay.example:80", "relay.example"),
            ("https://relay.example:3004", "relay.example:3004"),
            ("https://Relay.Example", "relay.example"),
        ]
    )
    func serverAuthority(base: String, expected: String) throws {
        let url = try #require(URL(string: base))
        #expect(MediaUploadClient.serverAuthority(of: url) == expected)
    }

    // MARK: - The request

    @Test("an upload PUTs to /upload")
    func uploadsToShortPath() async throws {
        let transport = RecordingTransport(answers: [(Data(Self.descriptorJSON.utf8), 200)])
        _ = try await Self.client(transport: transport)
            .upload(data: Data("hello".utf8), mimeType: "image/jpeg")
        #expect(await transport.requests.map(\.url.path) == ["/upload"])
        #expect(await transport.requests.first?.body == Data("hello".utf8))
    }

    /// The fallback is for a relay old enough to predate the short path. It is
    /// only reached on the two statuses that mean "no such endpoint" — a 500
    /// must not be retried against a second URL.
    @Test(
        "a relay without /upload is retried at /media/upload",
        arguments: [404, 405]
    )
    func fallsBackToLegacyPath(status: Int) async throws {
        let transport = RecordingTransport(answers: [
            (Data(), status),
            (Data(Self.descriptorJSON.utf8), 200),
        ])
        _ = try await Self.client(transport: transport)
            .upload(data: Data("hello".utf8), mimeType: "image/jpeg")
        #expect(await transport.requests.map(\.url.path) == ["/upload", "/media/upload"])
    }

    @Test("any other failure is not retried at a second path")
    func doesNotFallBackOnOtherFailures() async throws {
        let transport = RecordingTransport(answers: [(Data("boom".utf8), 500)])
        await #expect(throws: MediaUploadError.failed(status: 500, body: "boom")) {
            try await Self.client(transport: transport)
                .upload(data: Data("hello".utf8), mimeType: "image/jpeg")
        }
        #expect(await transport.requests.count == 1)
    }

    /// 415 and 422 on a type we do support is the relay's policy, not a broken
    /// upload — the one failure worth telling a reader about in its own words.
    @Test("a policy refusal is its own error", arguments: [415, 422])
    func policyRefusal(status: Int) async throws {
        let transport = RecordingTransport(answers: [(Data(), status)])
        await #expect(throws: MediaUploadError.rejectedByPolicy) {
            try await Self.client(transport: transport)
                .upload(data: Data("hello".utf8), mimeType: "image/jpeg")
        }
    }

    /// HEIC is what an iPhone camera writes and the relay does not take it, so
    /// it fails here rather than after the bytes have crossed the network.
    @Test("an unsupported type never reaches the network")
    func unsupportedTypeIsRefusedLocally() async throws {
        let transport = RecordingTransport(answers: [(Data(Self.descriptorJSON.utf8), 200)])
        await #expect(throws: MediaUploadError.unsupportedType("image/heic")) {
            try await Self.client(transport: transport)
                .upload(data: Data("hello".utf8), mimeType: "image/heic")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("a success carrying something other than a descriptor is a failure")
    func malformedSuccess() async throws {
        let transport = RecordingTransport(answers: [(Data("<html>".utf8), 200)])
        await #expect(throws: MediaUploadError.malformedResponse) {
            try await Self.client(transport: transport)
                .upload(data: Data("hello".utf8), mimeType: "image/jpeg")
        }
    }

    // MARK: - The answer

    @Test("the relay's measurements are carried onto the message's imeta tag")
    func imetaCarriesRelayMeasurements() async throws {
        let transport = RecordingTransport(answers: [(Data(Self.descriptorJSON.utf8), 200)])
        let descriptor = try await Self.client(transport: transport)
            .upload(data: Data("hello".utf8), mimeType: "image/jpeg")

        // The upload result remains the source of truth even though the client
        // also predicts these fields in DEBUG.
        #expect(descriptor.dim == "800x600")
        #expect(descriptor.blurhash == "L00000")
        #expect(descriptor.imetaTag() == [
            "imeta",
            "url https://relay.example/media/abc.jpg",
            "m image/jpeg",
            "x abc",
            "size 12",
            "dim 800x600",
            "blurhash L00000",
            "thumb https://relay.example/media/abc.thumb.jpg",
        ])
    }

    @Test("an image descriptor is predicted from the exact local bytes")
    func predictsImageDescriptor() throws {
        let picture = try #require(ImageFixture.png(width: 40, height: 24))
        let descriptor = try #require(BlobDescriptor.predicted(
            data: picture,
            baseURL: #require(URL(string: "https://tenant.example:8443/socket?old=1"))
        ))
        let digest = SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined()

        #expect(descriptor.url == "https://tenant.example:8443/media/\(digest).png")
        #expect(descriptor.sha256 == digest)
        #expect(descriptor.size == picture.count)
        #expect(descriptor.type == "image/png")
        #expect(descriptor.dim == "40x24")
        #expect(descriptor.blurhash?.count == 28)
        #expect(descriptor.thumb == "https://tenant.example:8443/media/\(digest).thumb.jpg")
    }

    @Test(
        "prediction uses the relay's exact four image extensions",
        arguments: [
            (ImageByteFormat.jpeg, "image/jpeg", "jpg"),
            (ImageByteFormat.png, "image/png", "png"),
            (ImageByteFormat.gif, "image/gif", "gif"),
            (ImageByteFormat.webp, "image/webp", "webp"),
        ]
    )
    func predictionExtension(
        format: ImageByteFormat,
        mimeType: String,
        fileExtension: String
    ) throws {
        let mapping = try #require(BlobDescriptor.predictedTypeAndExtension(for: format))
        #expect(mapping.mimeType == mimeType)
        #expect(mapping.extension == fileExtension)
    }

    @Test("HEIC has no predicted relay extension")
    func predictionRefusesHEIC() {
        #expect(BlobDescriptor.predictedTypeAndExtension(for: .heic) == nil)
    }

    @Test("a blob with nothing optional produces the four required entries only")
    func imetaOmitsAbsentFields() {
        let bare = BlobDescriptor(
            url: "https://relay.example/media/x.png",
            sha256: "deadbeef",
            size: 3,
            type: "image/png",
            uploaded: 1
        )
        #expect(bare.imetaTag() == [
            "imeta",
            "url https://relay.example/media/x.png",
            "m image/png",
            "x deadbeef",
            "size 3",
        ])
    }

    @Test("a picture is a markdown image, and a file is a link that names itself")
    func markdownReference() {
        func blob(_ type: String, filename: String? = nil) -> BlobDescriptor {
            BlobDescriptor(
                url: "https://relay.example/media/x",
                sha256: "x", size: 1, type: type, uploaded: 1, filename: filename
            )
        }
        #expect(blob("image/jpeg").markdownReference() == "![image](https://relay.example/media/x)")
        #expect(blob("video/mp4").markdownReference() == "![video](https://relay.example/media/x)")
        #expect(
            blob("application/pdf", filename: "report.pdf").markdownReference()
                == "[report.pdf](https://relay.example/media/x)"
        )
        // A bracket in a filename would otherwise close the link early.
        #expect(
            blob("application/pdf", filename: "a[1].pdf").markdownReference()
                == "[a\\[1\\].pdf](https://relay.example/media/x)"
        )
    }

    // MARK: - Helpers

    static func decodeAuthorizationEvent(_ header: String) throws -> NostrEvent {
        var encoded = String(header.dropFirst("Nostr ".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        let data = try #require(Data(base64Encoded: encoded))
        return try JSONDecoder().decode(NostrEvent.self, from: data)
    }
}

/// One recorded `PUT`. At file scope because a type nested two deep inside a
/// suite is a lint violation, not because anything else uses it.
struct RecordedUpload: Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data
}
