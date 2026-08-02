import Foundation
@testable import Hive
import Testing

@Suite("Message links")
struct MessageLinkTests {
    private let channel = "f570339f-8f8a-4e08-a779-8d954aa44109"
    private let message = "b04819ffc1f7c8ffb49c6d30b5899f470198264680d02e78894a658e30a9059f"
    private let thread = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

    @Test("a channel message uses the desktop top-level format and parses back")
    func topLevelRoundTrip() throws {
        let url = try #require(MessageLink.url(channelID: channel, messageID: message, threadRootID: nil))

        #expect(url.absoluteString == "buzz://message?channel=\(channel)&id=\(message)")
        #expect(RichTextTarget(url: url) == .message(channel: channel, event: message, thread: nil))
    }

    @Test("a reply includes its thread root and parses back")
    func threadedRoundTrip() throws {
        let url = try #require(MessageLink.url(channelID: channel, messageID: message, threadRootID: thread))

        #expect(url.absoluteString == "buzz://message?channel=\(channel)&id=\(message)&thread=\(thread)")
        #expect(RichTextTarget(url: url) == .message(channel: channel, event: message, thread: thread))
    }

    @Test("an empty thread root is omitted")
    func emptyThreadRootIsTopLevel() throws {
        let url = try #require(MessageLink.url(channelID: channel, messageID: message, threadRootID: ""))

        #expect(url.absoluteString == "buzz://message?channel=\(channel)&id=\(message)")
    }

    @Test("missing required values do not produce a link")
    func requiredValuesAreRequired() {
        #expect(MessageLink.url(channelID: "", messageID: message, threadRootID: nil) == nil)
        #expect(MessageLink.url(channelID: channel, messageID: "", threadRootID: nil) == nil)
    }
}
