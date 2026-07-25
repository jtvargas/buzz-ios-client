@testable import Hive
import NostrCore
import Testing

/// The outbound tag builders, round-tripped through the same resolver
/// (``NostrEvent/threadReference``) the projector reads — so "the markers are
/// correct" means the store threads the sent event exactly as intended.
@Suite("Outbound tags")
struct OutboundTagsTests {
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
}
