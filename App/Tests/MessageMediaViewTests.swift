import BuzzKit
import Foundation
@testable import Hive
import Testing

/// The view's own rules, as pure functions.
///
/// One rule, and it is the recycling one: a message row is reused for another message as
/// the conversation scrolls, and `@State` survives that reuse. ``RemoteImageDisplay``
/// already refuses to draw a decoded bitmap belonging to a subject the view has moved on
/// from; this is the same identity check applied to the *absence* of one, because a
/// failure notice inherited by the next message is the same defect wearing the opposite
/// hat.
@Suite("Message media view")
struct MessageMediaViewTests {
    static func url(_ string: String) -> URL? { URL(string: string) }
}

extension MessageMediaViewTests {
    @Test("a failure belongs to the source that produced it, and to no other")
    func failureIsKeyedToItsSource() throws {
        let subject = try #require(Self.url("https://relay.example/media/a.png"))
        let other = try #require(Self.url("https://relay.example/media/b.png"))

        // Nothing has failed yet.
        #expect(MessageMediaView.hasFailed(source: subject, failed: nil) == false)
        // This subject failed, and is drawn as failed.
        #expect(MessageMediaView.hasFailed(source: subject, failed: subject))
        // The row was recycled onto a different attachment. The previous message's
        // failure is not this one's, and must not be drawn over it while the new picture
        // loads.
        #expect(MessageMediaView.hasFailed(source: other, failed: subject) == false)
    }

    @Test("a URL that will not parse has failed before anything was attempted")
    func unparseableSourceIsAFailure() throws {
        // `MessageMedia.parse` accepts any non-empty `url` field that classifies by
        // extension, so the string reaching the view is not guaranteed to be a URL. There
        // is then no request to make and nothing to wait for, and the box says what the
        // attachment was rather than showing a placeholder that loads for ever.
        #expect(MessageMediaView.hasFailed(source: nil, failed: nil))
        let stale = try #require(Self.url("https://relay.example/media/a.png"))
        #expect(MessageMediaView.hasFailed(source: nil, failed: stale))
    }
}
