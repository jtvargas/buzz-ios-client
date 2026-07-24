@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport

/// Builds scripted `POST /query` window responses for the window-client tests.
///
/// Two identities model the two authorship classes NIP-CW mixes into one array:
/// a channel `member` signs the rows and the client-authored aux events, and a
/// `relay` identity signs the overlay kinds (`39005`/`39006`) and the relay
/// moderation tombstone (`9005`). The client never verifies overlay signatures
/// under the authenticated-transport profile, but signing everything properly
/// keeps the fixtures reusable by the step-6 engine tests, which do ingest the
/// rows and aux through the verifying choke point.
struct WindowResponseBuilder {
    let channel: String
    let member: Fixture
    let relay: Fixture

    init(channel: String = "2f8a1c4e-6b3d-4a9f-8e21-0c5d7b9a1e34") throws {
        self.channel = channel
        member = try Fixture()
        relay = try Fixture()
    }

    // MARK: Rows and aux (client-authored, ordinary signed events)

    func row(_ content: String, at seconds: Int64) throws -> NostrEvent {
        try member.event(.channelMessage, content, tags: [["h", channel]], at: seconds)
    }

    func reaction(on target: String, at seconds: Int64 = 1_700_000_310) throws -> NostrEvent {
        try member.event(.reaction, "+", tags: [["e", target], ["h", channel]], at: seconds)
    }

    func edit(of target: String, to content: String, at seconds: Int64 = 1_700_000_320) throws -> NostrEvent {
        try member.event(.messageEdit, content, tags: [["e", target], ["h", channel]], at: seconds)
    }

    func deletion(of target: String, at seconds: Int64 = 1_700_000_330) throws -> NostrEvent {
        try member.event(.deletion, "", tags: [["e", target], ["h", channel]], at: seconds)
    }

    func tombstone(of target: String, at seconds: Int64 = 1_700_000_340) throws -> NostrEvent {
        try relay.event(.groupDeleteEvent, "", tags: [["e", target], ["h", channel]], at: seconds)
    }

    // MARK: Overlays (relay-authored)

    func summary(for row: String, at seconds: Int64 = 1_700_000_350) throws -> NostrEvent {
        let content = "{\"reply_count\":1,\"descendant_count\":1,\"last_reply_at\":null,\"participants\":[]}"
        return try relay.event(
            .threadSummary, content,
            tags: [["e", row], ["d", row], ["h", channel]], at: seconds
        )
    }

    /// A bounds overlay with fully controlled `d`-tag suffix and content, so a test
    /// can forge any of the malformed variants T7 requires.
    func bounds(
        dSuffix: String,
        content: String,
        at seconds: Int64 = 1_700_000_360
    ) throws -> NostrEvent {
        try relay.event(
            .windowBounds, content,
            tags: [["d", "\(channel):\(dSuffix)"], ["h", channel]], at: seconds
        )
    }

    /// A well-formed head bounds overlay: `d` = `<channel>:head`, content encoding
    /// the given exhaustion state.
    func headBounds(hasMore: Bool, nextCursor: WindowCursor? = nil) throws -> NostrEvent {
        try bounds(dSuffix: "head", content: Self.boundsContent(hasMore: hasMore, nextCursor: nextCursor))
    }

    /// The `kind:39006` content JSON for an exhaustion state. `nextCursor` nil emits
    /// `"next_cursor":null`.
    static func boundsContent(hasMore: Bool, nextCursor: WindowCursor?) -> String {
        let cursorJSON: String
        if let nextCursor {
            cursorJSON = "{\"created_at\":\(nextCursor.createdAt),\"id\":\"\(nextCursor.id)\"}"
        } else {
            cursorJSON = "null"
        }
        return "{\"has_more\":\(hasMore),\"next_cursor\":\(cursorJSON)}"
    }

    /// Serializes a response array to the flat signed-event JSON body a relay returns.
    static func body(_ events: [NostrEvent]) throws -> Data {
        try JSONEncoder().encode(events)
    }
}

extension WindowClient {
    /// Fetches one page against a fake transport scripted with `body` at `status`.
    ///
    /// Convenience for the common "one request, one scripted response" shape, so a
    /// test reads as request → outcome without transport plumbing.
    static func fetch(
        _ filter: WindowFilter,
        respondingWith body: Data,
        status: Int = 200,
        signer: some EventSigner
    ) async throws -> (result: WindowResult, transport: FakeHTTPTransport) {
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: status, body: body)
        let url = URL(string: "https://relay.example.com/query")!
        let client = WindowClient(transport: transport, queryURL: url, signer: signer)
        let result = try await client.fetch(filter)
        return (result, transport)
    }
}
