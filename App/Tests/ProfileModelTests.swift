import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The profile editor publishes a kind-0 metadata event through the durable outbox
/// (``MessageSending``), carrying both `name` and `display_name`, and derives the
/// identity's `npub`.
@MainActor
@Suite struct ProfileModelTests {
    static let pubkey = "199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a"

    private func makeModel(sender: RecordingSender) throws -> (ProfileModel, TempStore) {
        let temp = TempStore()
        let store = try temp.open()
        return (ProfileModel(store: store, selfPubkey: Self.pubkey, sender: sender), temp)
    }

    @Test func savePublishesKind0ThroughTheOutbox() async throws {
        let sender = try RecordingSender()
        let (model, temp) = try makeModel(sender: sender)
        defer { temp.remove() }

        model.draftDisplayName = "Alice"
        model.draftAbout = "hello there"
        await model.save()

        #expect(model.didSave)
        let sent = await sender.sent
        #expect(sent.count == 1)
        #expect(sent.first?.kind == .metadata)
        #expect(sent.first?.channel == "") // channel-less, like read state
        let content = sent.first?.content ?? ""
        #expect(content.contains(#""display_name":"Alice""#))
        #expect(content.contains(#""name":"Alice""#))
        #expect(content.contains(#""about":"hello there""#))
    }

    @Test func blankFieldsAreOmitted() async throws {
        let sender = try RecordingSender()
        let (model, temp) = try makeModel(sender: sender)
        defer { temp.remove() }

        model.draftDisplayName = "   "
        model.draftAbout = ""
        await model.save()

        let content = await sender.sent.first?.content ?? ""
        #expect(!content.contains("display_name"))
        #expect(!content.contains("about"))
    }

    @Test func derivesNpub() throws {
        let (model, temp) = try makeModel(sender: try RecordingSender())
        defer { temp.remove() }
        #expect(model.npub == (PublicKey(hex: Self.pubkey)?.npub))
        #expect(model.npub.hasPrefix("npub1"))
    }
}
