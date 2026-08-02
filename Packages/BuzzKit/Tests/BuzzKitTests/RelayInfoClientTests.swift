@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// What a host has to answer before Hive will call it a community.
///
/// This is the only thing a phone can learn about a relay it is not a member of, and it is
/// shown to somebody deciding whether to join — so the two things worth asserting are that
/// the request is the one a Buzz relay answers with its document rather than with its web
/// app, and that everything read out of the answer is refused by default. The bytes come from
/// a host nobody has agreed to trust yet.
@Suite("Relay information")
struct RelayInfoClientTests {
    /// Answers from a script, and records what it was asked.
    actor ScriptedTransport: InviteTransport {
        private(set) var requests: [(URL, [String: String])] = []
        private var answers: [(Data, Int)]
        private let failure: TransportError?

        init(answers: [(Data, Int)] = [], failure: TransportError? = nil) {
            self.answers = answers
            self.failure = failure
        }

        func get(from url: URL, headers: [String: String]) async throws -> (Data, Int) {
            requests.append((url, headers))
            if let failure { throw failure }
            return answers.isEmpty ? (Data(), 500) : answers.removeFirst()
        }

        func post(body _: Data, to _: URL, headers _: [String: String]) async throws -> (Data, Int) {
            (Data(), 405)
        }
    }

    static func client(
        _ transport: ScriptedTransport,
        relay: String = "wss://relay.example"
    ) throws -> RelayInfoClient {
        try #require(RelayInfoClient(relayURLString: relay, transport: transport))
    }

    // MARK: - The request

    /// The relay's origin, and the header that gets the document rather than the SPA. Without
    /// `Accept: application/nostr+json` the same URL answers HTML, and the decode below would
    /// report a perfectly good Buzz relay as unreadable.
    @Test func asksTheRelaysOriginForTheDocumentAndNotForItsWebApp() async throws {
        let transport = ScriptedTransport(answers: [(Data("{}".utf8), 200)])
        _ = try? await Self.client(transport, relay: "wss://relay.example:7777").fetch()

        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.0.absoluteString == "https://relay.example:7777")
        #expect(requests.first?.1["Accept"] == "application/nostr+json")
    }

    /// A `ws` relay is reached over plaintext HTTP, because that is the only thing serving it.
    @Test func aPlaintextRelayIsAskedOverPlaintext() async throws {
        let transport = ScriptedTransport(answers: [(Data("{}".utf8), 200)])
        _ = try? await Self.client(transport, relay: "ws://localhost:3004").fetch()

        let requests = await transport.requests
        #expect(requests.first?.0.absoluteString == "http://localhost:3004")
    }

    // MARK: - What is read back

    @Test func readsTheIconAndTheSoftwareAndNothingElse() async throws {
        let body = """
        {"name":"Buzz Relay","description":"Buzz — private team communication relay",
         "software":"https://github.com/block/buzz","version":"0.4.0",
         "icon":"data:image/png;base64,\(Self.onePixelPNG)"}
        """
        let transport = ScriptedTransport(answers: [(Data(body.utf8), 200)])

        let info = try await Self.client(transport).fetch()

        #expect(info.isBuzzRelay)
        guard case let .inline(data) = info.communityIcon else {
            Issue.record("A base64 data URL is the form a hosted Buzz relay serves")
            return
        }
        #expect(!data.isEmpty)
    }

    /// The honest half of the badge. A plain Nostr relay answers this document too and has no
    /// invite API at all, so treating any answer as a Buzz community would promise a join that
    /// cannot happen.
    @Test func aRelayThatIsNotBuzzIsNotAVerifiedCommunity() async throws {
        let body = #"{"name":"strfry","software":"git+https://github.com/hoytech/strfry.git"}"#
        let transport = ScriptedTransport(answers: [(Data(body.utf8), 200)])

        let info = try await Self.client(transport).fetch()

        #expect(!info.isBuzzRelay)
    }

    /// A relay from before a field existed, or one that is not Buzz at all, must still be
    /// readable — the point of the fetch is to find out what answered.
    @Test func aDocumentMissingEveryFieldIsStillADocument() async throws {
        let transport = ScriptedTransport(answers: [(Data("{}".utf8), 200)])

        let info = try await Self.client(transport).fetch()

        #expect(info.icon == nil)
        #expect(!info.isBuzzRelay)
        #expect(info.communityIcon == nil)
    }

    @Test func aNonSuccessAndAnUnreadableBodyAreDistinguished() async throws {
        let refused = ScriptedTransport(answers: [(Data(), 403)])
        await #expect(throws: RelayInfoError.httpStatus(403)) {
            _ = try await Self.client(refused).fetch()
        }

        let html = ScriptedTransport(answers: [(Data("<!doctype html>".utf8), 200)])
        await #expect(throws: RelayInfoError.unreadableResponse) {
            _ = try await Self.client(html).fetch()
        }
    }

    // MARK: - The icon, which is bytes from a host nobody trusts yet

    @Test func onlyABase64ImageDataURLIsDecoded() {
        #expect(RelayIcon(source: "data:image/png;base64,\(Self.onePixelPNG)") != nil)
        // Not an image.
        #expect(RelayIcon(source: "data:text/html;base64,\(Self.onePixelPNG)") == nil)
        // Percent-encoded rather than base64: refused rather than supported, because every
        // additional accepted spelling is another way for bytes to reach an image decoder.
        #expect(RelayIcon(source: "data:image/svg+xml,%3Csvg%2F%3E") == nil)
        #expect(RelayIcon(source: "data:image/png;base64,") == nil)
        #expect(RelayIcon(source: "") == nil)
    }

    /// A remote icon is fetched, so the scheme is the whole of the protection: an unjoined
    /// host has no business making this phone issue a plaintext request.
    @Test func aRemoteIconMustBeHTTPS() throws {
        let secure = try #require(URL(string: "https://cdn.example/icon.png"))
        #expect(RelayIcon(source: secure.absoluteString) == .remote(secure))
        #expect(RelayIcon(source: "http://cdn.example/icon.png") == nil)
        #expect(RelayIcon(source: "file:///etc/passwd") == nil)
    }

    /// The one field in this document whose size the operator chooses, served to anybody.
    @Test func anOversizedInlineIconIsRefused() {
        let huge = Data(repeating: 0, count: RelayIcon.maximumInlineBytes + 1).base64EncodedString()
        #expect(RelayIcon(source: "data:image/png;base64,\(huge)") == nil)

        let allowed = Data(repeating: 0, count: RelayIcon.maximumInlineBytes).base64EncodedString()
        #expect(RelayIcon(source: "data:image/png;base64,\(allowed)") != nil)
    }

    /// A 1x1 PNG, so the decode has real bytes to produce.
    static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
}
