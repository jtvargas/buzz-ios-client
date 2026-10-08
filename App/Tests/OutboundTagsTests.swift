@testable import Hive
import NostrCore
import Testing

/// The outbound tag builders, round-tripped through the same resolver
/// (``NostrEvent/threadReference``) the projector reads — so "the markers are
/// correct" means the store threads the sent event exactly as intended.
@Suite("Outbound tags")
struct OutboundTagsTests {
    @Test("message mention tags are normalized, deduplicated, sender-excluded, and capped")
    func mentionTags() {
        let sender = String(repeating: "f", count: 64)
        let first = String(repeating: "A", count: 64)
        let tags = OutboundTags.message(
            channel: "room-1",
            mentioning: [first, first.lowercased(), sender],
            sender: sender
        )
        #expect(tags == [["h", "room-1"], ["p", first.lowercased()]])
    }

    @MainActor
    @Test("plain composer sends tag DM peers only", arguments: ["dm", "stream"], [1, 2])
    func automaticDMRecipients(channelType: String, peerCount: Int) async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let peers = try (0 ..< peerCount).map { _ in try Fixture().pubkey }
        _ = try await store.ingest(batch: [
            author.event(.groupMetadata, "", tags: [["d", "room"], ["t", channelType]]),
            author.channelMembers("room", [author.pubkey] + peers),
        ], phase: .backfill)

        let sender = try RecordingSender()
        let timeline = ChannelTimelineModel(
            channel: "room", store: store, sender: sender, selfPubkey: author.pubkey.uppercased()
        )
        timeline.draft = "hello"
        timeline.send()
        await waitUntil { await sender.sent.count == 1 }

        let thread = ThreadModel(
            root: "ROOT", channel: "room", store: store, sender: sender,
            opener: StubThreadOpener(store: store, events: []), selfPubkey: author.pubkey.uppercased()
        )
        thread.draft = "hello"
        thread.sendReply()
        await waitUntil { await sender.sent.count == 2 }

        let expected = channelType == "dm" ? Set(peers) : Set<String>()
        for event in await sender.events {
            #expect(event.content == "hello")
            #expect(Set(event.tags.filter { $0.first == "p" }.map { $0[1] }) == expected)
        }
        let reply = try #require(await sender.events.last)
        #expect(reply.threadReference.rootID == "ROOT")
    }

    private func signed(_ kind: EventKind, tags: [[String]]) throws -> NostrEvent {
        try Fixture().event(kind, "x", tags: tags)
    }

    @Test("a direct reply to the thread head threads parent = root = head")
    func directReply() throws {
        let tags = OutboundTags.reply(channel: "room-1", root: "ROOT", parent: "ROOT")
        #expect(tags == [["h", "room-1"], ["e", "ROOT", "", "reply"]])

        let event = try signed(.channelMessage, tags: tags)
        #expect(event.groupID == "room-1")
        #expect(event.threadReference.parentID == "ROOT")
        #expect(event.threadReference.rootID == "ROOT")
        #expect(event.isThreadReply)
    }

    @Test("a nested reply threads parent = target and root = thread head")
    func nestedReply() throws {
        let tags = OutboundTags.reply(channel: "room-1", root: "ROOT", parent: "PARENT")
        #expect(tags == [["h", "room-1"], ["e", "ROOT", "", "root"], ["e", "PARENT", "", "reply"]])

        let event = try signed(.channelMessage, tags: tags)
        #expect(event.threadReference.parentID == "PARENT")
        #expect(event.threadReference.rootID == "ROOT")
    }

    @Test("typing at the channel's own level carries the h scope and no e marker")
    func channelTyping() throws {
        #expect(OutboundTags.typing(channel: "room-1", thread: nil) == [["h", "room-1"]])
    }

    @Test("typing in a thread scopes exactly as the reply it precedes")
    func threadTyping() throws {
        let tags = OutboundTags.typing(channel: "room-1", thread: "ROOT")
        #expect(tags == OutboundTags.reply(channel: "room-1", root: "ROOT", parent: "ROOT"))

        // What a reader's scope resolves to: the thread, not the channel.
        let event = try signed(.typing, tags: tags)
        #expect(event.groupID == "room-1")
        #expect(event.threadReference.rootID == "ROOT")
    }

    @Test("a reaction references only its target, which the projector reads as such")
    func reaction() throws {
        let tags = OutboundTags.reaction(target: "TARGET")
        #expect(tags == [["e", "TARGET"]])

        let event = try signed(.reaction, tags: tags)
        #expect(event.referencedEventIDs.last == "TARGET")
    }

    @Test("a withdrawal references the reaction it removes")
    func withdrawal() throws {
        let tags = OutboundTags.withdrawal(reactionID: "REACTION")
        #expect(tags == [["e", "REACTION"]])

        let event = try signed(.deletion, tags: tags)
        #expect(event.referencedEventIDs == ["REACTION"])
    }

    @Test("a deletion carries the channel scope the relay validates the target against")
    func deletion() throws {
        let tags = OutboundTags.deletion(channel: "room", target: "TARGET")
        // The `h` is load-bearing, not decoration: the relay rejects a 9005 whose target
        // does not belong to the h-tagged channel, which is what stops a deletion in one
        // room reaching into another.
        #expect(tags == [["h", "room"], ["e", "TARGET"]])

        let event = try signed(.groupDeleteEvent, tags: tags)
        #expect(event.referencedEventIDs == ["TARGET"])
    }

    @Test("an edit names exactly one target, because the projector takes the last e tag")
    func edit() throws {
        let tags = OutboundTags.edit(channel: "room", target: "TARGET")
        #expect(tags == [["h", "room"], ["e", "TARGET"]])

        let event = try signed(.messageEdit, tags: tags)
        // Exactly one, not merely a correct last one: a second `e` here would silently
        // rewrite whichever message came last in the list.
        #expect(event.referencedEventIDs == ["TARGET"])
    }
}
