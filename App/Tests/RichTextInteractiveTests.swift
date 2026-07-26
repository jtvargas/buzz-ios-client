import Foundation
@testable import Hive
import Testing

/// The interactive half of the render engine: what becomes a link, what that link
/// carries, what a press routes to, and how an inline is cut into the segments the
/// pill renderer draws. All values — no view host.
@Suite("Interactive rich text")
struct RichTextInteractiveTests {
    private func message(_ text: String, _ resolver: MentionResolver = StubMentionResolver()) -> [RichBlock] {
        RichMessage.make(text, resolver: resolver).blocks
    }

    private func inline(_ text: String, _ resolver: MentionResolver = StubMentionResolver()) -> AttributedString {
        RichTextProbe.inline(of: message(text, resolver)[0])
    }

    /// Every link in an inline, as `(visibleText, url)`.
    private func links(_ attributed: AttributedString) -> [(text: String, url: URL)] {
        attributed.runs.compactMap { run in
            run.link.map { (String(attributed[run.range].characters), $0) }
        }
    }

    // MARK: - Autolinking plain text

    @Test("a bare web URL in plain text becomes a link")
    func bareURL() {
        let found = links(inline("notes are at https://example.com/a/b now"))
        #expect(found.count == 1)
        #expect(found.first?.text == "https://example.com/a/b")
        #expect(found.first?.url.absoluteString == "https://example.com/a/b")
    }

    @Test("a bare email address becomes a mailto link")
    func bareEmail() {
        let found = links(inline("write to ada@example.com about it"))
        #expect(found.count == 1)
        #expect(found.first?.text == "ada@example.com")
        #expect(found.first?.url.scheme == "mailto")
    }

    @Test("a full stop after a URL is not part of the link")
    func trailingPunctuation() {
        let found = links(inline("see https://example.com/a."))
        #expect(found.first?.text == "https://example.com/a")
    }

    @Test("several links in one message all resolve")
    func multipleLinks() {
        let found = links(inline("https://a.example and https://b.example and mail@c.example"))
        #expect(found.count == 3)
        #expect(found.map(\.url.scheme) == ["https", "https", "mailto"])
    }

    @Test("a URL inside a code span is not linked")
    func codeSpanNotLinked() {
        #expect(links(inline("run `curl https://example.com/x` first")).isEmpty)
    }

    @Test("a fenced code block is not linked")
    func codeBlockNotLinked() {
        let blocks = message("```\nhttps://example.com/x\n```")
        #expect(RichTextProbe.firstLink(blocks) == nil)
    }

    @Test("an authored markdown link keeps its label and its destination")
    func authoredLinkUntouched() {
        let found = links(inline("read [the notes](https://example.com/notes) today"))
        #expect(found.count == 1)
        #expect(found.first?.text == "the notes")
        #expect(found.first?.url.absoluteString == "https://example.com/notes")
    }

    @Test("an authored link with an unsafe scheme keeps its text and loses the link")
    func unsafeSchemeStripped() {
        let inline = inline("tap [here](javascript:alert(1)) now")
        #expect(links(inline).isEmpty)
        #expect(String(inline.characters).contains("here"))
    }

    @Test("an authored link cannot impersonate a resolved mention")
    func authoredEntitySchemeStripped() {
        #expect(links(inline("[Ada](hive-entity://user/PK_SOMEONE_ELSE)")).isEmpty)
    }

    // MARK: - Internal links

    @Test("a bare buzz://message link becomes a link")
    func internalMessageLink() {
        let found = links(inline("here: buzz://message?channel=CH1&id=EV1 — see it"))
        #expect(found.count == 1)
        #expect(found.first?.url.absoluteString == "buzz://message?channel=CH1&id=EV1")
    }

    @Test("a buzz link the app cannot route stays plain text")
    func unroutableInternalLink() {
        #expect(links(inline("buzz://join?relay=wss%3A%2F%2Fx.example&code=abc")).isEmpty)
        #expect(links(inline("buzz://message?channel=CH1")).isEmpty)
    }

    // MARK: - Entities beside links

    @Test("an anchor in a URL is not read as a channel reference")
    func anchorIsNotAChannel() {
        let resolver = StubMentionResolver(channels: ["design": "CH_DESIGN"])
        let inline = inline("https://example.com/x#design", resolver)
        #expect(RichTextProbe.channelRuns(inline).isEmpty)
        #expect(links(inline).count == 1)
    }

    @Test("an email address is not read as a mention")
    func emailIsNotAMention() {
        let resolver = StubMentionResolver(members: ["example": MentionMatch(pubkey: "PK", isSelf: false)])
        let inline = inline("ada@example.com", resolver)
        #expect(RichTextProbe.mentionRuns(inline).isEmpty)
    }

    // MARK: - Targets

    @Test("a target round-trips through its URL")
    func targetRoundTrip() throws {
        let targets: [RichTextTarget] = [
            .user(pubkey: "abc123"),
            .channel(id: "9a1657ac-f7aa-5db0-b632-d8bbeb6dfb50"),
            .message(channel: "CH1", event: "EV1", thread: nil),
            .message(channel: "CH1", event: "EV1", thread: "ROOT1"),
        ]
        for target in targets {
            let url = try #require(target.url)
            #expect(RichTextTarget(url: url) == target)
        }
    }

    @Test("an unroutable URL produces no target and no route")
    func unroutableURL() {
        let url = URL(string: "ftp://example.com/x")!
        #expect(RichTextTarget(url: url) == nil)
        #expect(RichTextRoute(url: url) == nil)
    }

    // MARK: - Routing

    @Test("a mention routes to the profile sheet, carrying the pubkey and not the name")
    func mentionRoutesToProfile() throws {
        let url = try #require(RichTextTarget.user(pubkey: "PK_ADA").url)
        #expect(RichTextRoute(url: url) == .profile(pubkey: "PK_ADA"))
    }

    @Test("a channel reference routes to that conversation")
    func channelRoutesToConversation() throws {
        let url = try #require(RichTextTarget.channel(id: "CH_DESIGN").url)
        #expect(RichTextRoute(url: url) == .conversation(channelID: "CH_DESIGN"))
    }

    @Test("an internal message link routes to the conversation it names")
    func messageLinkRoutesToConversation() throws {
        let url = try #require(RichTextTarget.message(channel: "CH1", event: "EV1", thread: "R1").url)
        #expect(RichTextRoute(url: url) == .conversation(channelID: "CH1"))
    }

    @Test("web and email links route to the system handler")
    func externalRoutes() {
        let web = URL(string: "https://example.com/x")!
        let mail = URL(string: "mailto:ada@example.com")!
        #expect(RichTextRoute(url: web) == .external(web))
        #expect(RichTextRoute(url: mail) == .external(mail))
    }

    // MARK: - Styling

    @Test("styling a message for reading makes its entities pressable")
    func interactiveStyling() {
        let resolver = StubMentionResolver(
            members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)],
            channels: ["design": "CH_DESIGN"]
        )
        let styled = RichTextStyle.styled(
            inline("@ada see #design", resolver),
            base: .body,
            interactive: true
        )
        let found = links(styled)
        #expect(found.map(\.text) == ["@ada", "#design"])
        #expect(RichTextRoute(url: found[0].url) == .profile(pubkey: "PK_ADA"))
        #expect(RichTextRoute(url: found[1].url) == .conversation(channelID: "CH_DESIGN"))
    }

    @Test("styling a one-line preview strips every link, including authored ones")
    func snippetStylingIsInert() {
        let resolver = StubMentionResolver(members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)])
        let styled = RichTextStyle.styled(
            inline("@ada see https://example.com/x", resolver),
            base: .body,
            interactive: false
        )
        #expect(links(styled).isEmpty)
    }

    // MARK: - Segmentation

    @Test("a mention split by emphasis is one segment, so it draws one pill")
    func emphasisDoesNotSplitAPill() {
        let resolver = StubMentionResolver(members: ["ada lovelace": MentionMatch(pubkey: "PK", isSelf: false)])
        let styled = RichTextStyle.styled(
            inline("hi @**ada** lovelace!", resolver),
            base: .body,
            interactive: true
        )
        let interactive = RichTextSegments.segments(of: styled).filter { $0.link != nil }
        #expect(interactive.count == 1)
        #expect(String(styled[interactive[0].range].characters) == "@ada lovelace")
    }

    @Test("two mentions in a row are two segments")
    func adjacentMentionsStaySeparate() {
        let resolver = StubMentionResolver(members: [
            "ada": MentionMatch(pubkey: "PK_A", isSelf: false),
            "will": MentionMatch(pubkey: "PK_W", isSelf: false),
        ])
        let styled = RichTextStyle.styled(inline("@ada @will", resolver), base: .body, interactive: true)
        let interactive = RichTextSegments.segments(of: styled).filter { $0.link != nil }
        #expect(interactive.count == 2)
    }

    @Test("plain text between two links is its own segment")
    func plainTextIsSegmented() {
        let styled = RichTextStyle.styled(
            inline("https://a.example then https://b.example"),
            base: .body,
            interactive: true
        )
        let segments = RichTextSegments.segments(of: styled)
        #expect(segments.count == 3)
        #expect(segments.map { $0.link != nil } == [true, false, true])
    }

    @Test("an inline with nothing interactive is one segment")
    func plainInlineIsOneSegment() {
        let styled = RichTextStyle.styled(inline("just words here"), base: .body, interactive: true)
        #expect(RichTextSegments.segments(of: styled).count == 1)
        #expect(RichTextSegments.segments(of: styled).first?.link == nil)
    }

    // MARK: - Everything at once

    @Test("mentions, channels, links and emails mix in one multiline message")
    func mixedMultiline() {
        let resolver = StubMentionResolver(
            members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)],
            channels: ["design": "CH_DESIGN"]
        )
        let blocks = message(
            """
            @ada — notes in #design.
            Mirror: https://example.com/notes, or mail ada@example.com.
            """,
            resolver
        )
        let styled = blocks.map {
            RichTextStyle.styled(RichTextProbe.inline(of: $0), base: .body, interactive: true)
        }
        let routes = styled.flatMap { links($0) }.compactMap { RichTextRoute(url: $0.url) }
        #expect(routes.count == 4)
        #expect(routes[0] == .profile(pubkey: "PK_ADA"))
        #expect(routes[1] == .conversation(channelID: "CH_DESIGN"))
        if case .external = routes[2] {} else { Issue.record("expected the web link to be external") }
        if case .external = routes[3] {} else { Issue.record("expected the email to be external") }
    }

    @Test("a list item's links are interactive too")
    func listItemsAreInteractive() {
        let blocks = message("- see https://example.com/x")
        guard case let .bulletList(items) = blocks[0] else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(links(items[0].content).count == 1)
    }
}

/// The pill geometry the renderer draws, as values: `Text.Layout.Line` cannot be built
/// in a test, so the merge rule is separated from the draw that applies it.
@Suite("Rich text pills")
struct RichTextPillTests {
    private func rect(_ originX: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: originX, y: 0, width: width, height: 20)
    }

    @Test("adjacent runs of one mention merge into a single pill")
    func adjacentRunsMerge() {
        // `@**Ada** Lovelace`: three layout runs, one range, one pill — three fills
        // would overlap their padding and show as brighter seams around the bold word.
        let merged = RichTextEntityRenderer.merged([
            ("ada", rect(0, width: 10)),
            ("ada", rect(10, width: 30)),
            ("ada", rect(40, width: 50)),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].rect == rect(0, width: 90))
    }

    @Test("two references to the same person on one line stay two pills")
    func repeatedKeyDoesNotMergeAcrossText() {
        let merged = RichTextEntityRenderer.merged([
            ("ada", rect(0, width: 40)),
            (nil, rect(40, width: 60)),
            ("ada", rect(100, width: 40)),
        ])
        #expect(merged.count == 2)
        #expect(merged.map(\.rect.width) == [40, 40])
    }

    @Test("two different entities side by side are two pills")
    func differentKeysDoNotMerge() {
        let merged = RichTextEntityRenderer.merged([
            ("ada", rect(0, width: 40)),
            ("will", rect(40, width: 40)),
        ])
        #expect(merged.count == 2)
    }

    @Test("a line with nothing interactive has no pills")
    func noPills() {
        #expect(RichTextEntityRenderer.merged([(nil, rect(0, width: 100))]).isEmpty)
    }
}
