import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The premise ``ConversationSendScrollTests`` rests on: what the fixture's composer sends is
/// really queued, and really comes back out of the timeline read.
///
/// A UI suite cannot tell "the surface did not scroll to the message" from "there was no
/// message", and it reports both as the same failure. This is the half that can be asked
/// without a simulator.
@MainActor
@Suite("Conversation fixture sender", .timeLimit(.minutes(1)))
struct ConversationFixtureSenderTests {
    @Test("what the fixture sends is queued and read back as a pending row")
    func storesWhatItSends() async throws {
        let store = try ConversationFixture.makeStore()
        let sender = ConversationFixture.StoringSender(
            store: store,
            signer: InMemorySigner(try PrivateKey())
        )

        let entry = try await sender.enqueue(
            kind: .channelMessage,
            content: "Message 999 from the composer",
            in: ConversationFixture.channelID,
            tags: OutboundTags.message(
                channel: ConversationFixture.channelID,
                mentioning: [],
                sender: nil
            ),
            maxContentBytes: OutboxPolicy.maxContentBytes
        )

        let rows = try await store.timeline(channel: ConversationFixture.channelID, before: nil, limit: 50)
        #expect(rows.map(\.id) == [entry.event.id])
        #expect(rows.first?.content == "Message 999 from the composer")
    }
}
