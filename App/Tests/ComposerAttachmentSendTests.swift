import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// What an attached picture puts on the wire.
///
/// Both halves are asserted, because neither is redundant: the `imeta` **tag** is
/// what lets a reader reserve the picture's space before a byte of it arrives, and
/// the markdown **reference** in the body is what a client that has never heard of
/// `imeta` renders — and what decides where in the message the picture sits.
@MainActor
@Suite("Sending with attachments", .timeLimit(.minutes(1)))
struct ComposerAttachmentSendTests {
    /// The closure is `async` so a condition may read an actor — the recorded sends
    /// and the parked uploads both live on one.
    static func waitUntil(
        _ condition: @MainActor () async -> Bool,
        within seconds: Double = 5
    ) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Attaches `count` named pictures and waits for local preparation. The names
    /// make the eventual descriptors distinguishable — see
    /// ``StubUploader/descriptor(key:mimeType:size:)``.
    static func attach(_ count: Int, to model: ComposerAttachmentsModel, through uploader: StubUploader) async {
        model.add((0 ..< count).map { StubPickedItem(data: TestPicture.png(), suggestedFilename: "pic-\($0)") })
        while model.isAttaching {
            await uploader.releaseAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - A channel message

    @Test("a message carries an imeta tag and a markdown reference per picture")
    func channelSendCarriesBothHalves() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = try RecordingSender()
        let uploader = StubUploader()
        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: sender, uploader: { uploader }
        )

        await Self.attach(2, to: model.attachments, through: uploader)
        model.mentionDraft = MentionDraft(text: "look at these")
        model.send()
        await Self.waitUntil { await uploader.parkedCount == 2 }
        await uploader.releaseAll()
        await Self.waitUntil { await !sender.sent.isEmpty }

        let sent = try #require(await sender.sent.first)
        let urls = ["pic-0", "pic-1"].map {
            StubUploader.descriptor(key: $0, mimeType: "image/png", size: 0).url
        }

        // The body: the author's words, then one reference per picture, in the
        // order they were picked — not the order their uploads happened to finish.
        #expect(sent.content == "look at these\n![image](\(urls[0]))\n![image](\(urls[1]))")

        // The tags: two `imeta`, in the same order, each describing its own blob.
        let imeta = sent.tags.filter { $0.first == "imeta" }
        #expect(imeta.count == 2)
        #expect(imeta[0].contains("url \(urls[0])"))
        #expect(imeta[0].contains("m image/png"))
        #expect(imeta[0].contains("dim 800x600"))
        #expect(imeta[1].contains("url \(urls[1])"))

        // The channel tag the message always carried is still there.
        #expect(sent.tags.contains(["h", "room-1"]))
        #expect(model.attachments.attachments.isEmpty)
        #expect(model.mentionDraft.text.isEmpty)
    }

    /// A picture with no words is a message. The body is the reference alone — no
    /// leading blank line, which is the one place this differs from the mobile
    /// client's own composition.
    @Test("a picture sends with no text at all")
    func pictureWithoutText() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = try RecordingSender()
        let uploader = StubUploader()
        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: sender, uploader: { uploader }
        )

        await Self.attach(1, to: model.attachments, through: uploader)
        model.send()
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { await !sender.sent.isEmpty }

        let sent = try #require(await sender.sent.first)
        let url = StubUploader.descriptor(key: "pic-0", mimeType: "image/png", size: 0).url
        #expect(sent.content == "![image](\(url))")
        #expect(sent.content.first != "\n")
    }

    @Test("a failed upload keeps the draft and pictures ready to send again")
    func failedUploadPreservesDraftForRetry() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = try RecordingSender()
        let uploader = StubUploader()
        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: sender, uploader: { uploader }
        )

        await Self.attach(1, to: model.attachments, through: uploader)
        model.mentionDraft = MentionDraft(text: "too soon")
        model.send()
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll(.failure(.rejectedByPolicy))
        await Self.waitUntil { model.attachments.uploadError != nil }

        #expect(await sender.sent.isEmpty)
        #expect(model.mentionDraft.text == "too soon")
        #expect(model.attachments.attachments.count == 1)

        // Sending again uploads only the row that returned to local-ready.
        model.send()
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { await !sender.sent.isEmpty }
        #expect(await sender.sent.count == 1)
    }

    @Test("an empty draft with nothing attached still sends nothing")
    func emptySendIsStillRefused() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = try RecordingSender()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: sender)

        model.send()
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await sender.sent.isEmpty)
    }

    // MARK: - A thread reply

    @Test("a reply carries its pictures the same way, and keeps its thread markers")
    func threadReplyCarriesBothHalves() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = try RecordingSender()
        let uploader = StubUploader()
        let model = ThreadModel(
            root: "root-1",
            channel: "room-1",
            store: store,
            sender: sender,
            opener: StubThreadOpener(store: store, events: []),
            uploader: { uploader },
            selfPubkey: nil
        )

        await Self.attach(1, to: model.attachments, through: uploader)
        model.mentionDraft = MentionDraft(text: "here")
        model.sendReply()
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { await !sender.sent.isEmpty }

        let sent = try #require(await sender.sent.first)
        let url = StubUploader.descriptor(key: "pic-0", mimeType: "image/png", size: 0).url
        #expect(sent.content == "here\n![image](\(url))")
        #expect(sent.tags.filter { $0.first == "imeta" }.count == 1)
        // The NIP-10 marker the reply cannot go without. One, not two: a reply
        // whose parent *is* the root carries a single `reply` marker — see
        // ``OutboundTags/reply(channel:root:parent:mentioning:sender:)``. Attaching
        // a picture must not disturb it.
        #expect(sent.tags.filter { $0.first == "e" } == [["e", "root-1", "", "reply"]])
        #expect(sent.tags.contains(["h", "room-1"]))
    }

    // MARK: - Composition

    /// The composition on its own, where the ordering rule is easiest to read.
    @Test("the body is the text then one reference per picture, in pick order")
    func compositionOrdering() {
        let first = StubUploader.descriptor(key: "one", mimeType: "image/png", size: 1)
        let second = StubUploader.descriptor(key: "two", mimeType: "image/jpeg", size: 2)

        #expect(
            OutboundAttachments.content("words", attaching: [first, second])
                == "words\n![image](\(first.url))\n![image](\(second.url))"
        )
        #expect(OutboundAttachments.content("", attaching: [first]) == "![image](\(first.url))")
        #expect(OutboundAttachments.content("words", attaching: []) == "words")
        #expect(OutboundAttachments.tags(attaching: [first, second]).map(\.first) == ["imeta", "imeta"])
    }

    /// What Hive sends, Hive reads: the tags it writes parse back into the media
    /// model the renderer draws from. The round trip is the guarantee that a
    /// picture sent from this client appears in it.
    @Test("the tags a send writes parse back into renderable media")
    func tagsRoundTripThroughTheParser() {
        let descriptor = StubUploader.descriptor(key: "one", mimeType: "image/png", size: 42)

        let media = MessageMedia.parse(tags: OutboundAttachments.tags(attaching: [descriptor]))

        #expect(media.count == 1)
        #expect(media.first?.url == descriptor.url)
        #expect(media.first?.kind == .image)
        // `dim` is what lets the row reserve the picture's space before it loads.
        #expect(media.first?.pixelSize == CGSize(width: 800, height: 600))
    }
}
