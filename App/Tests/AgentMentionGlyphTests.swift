import BuzzKit
import CoreGraphics
@testable import Hive
import Testing

/// The agent-mention glyph, in the three places it has a rule rather than a picture:
/// the flag reaching the token, the memo key that decides whether a cached render is
/// still valid, and the geometry that puts a 24-unit icon on a line of text.
///
/// The *drawing* is not here and cannot be: a `TextRenderer` needs a laid-out
/// `Text.Layout`, which cannot be built outside a view host, and `Text.customAttribute`
/// is invisible to everything else. It was verified by measuring a screenshot instead —
/// see the numbers in ``AgentGlyph``.
@Suite("Agent mention glyph")
struct AgentMentionGlyphTests {
    private let agent = String(repeating: "a", count: 64)
    private let person = String(repeating: "b", count: 64)

    // MARK: - The flag reaching the token

    @Test("a mention of an agent carries isAgent through to the token")
    func agentMentionIsFlagged() {
        let resolver = MessageMentionResolver(
            mentions: [MentionRef(pubkey: agent, displayName: "Bumble")],
            channels: .empty,
            selfPubkey: nil,
            agentPubkeys: [agent]
        )
        let blocks = RichTextEntities.resolve(RichTextParser.parse("ping @Bumble"), with: resolver)
        let token = RichTextProbe.firstMention(RichTextProbe.inline(of: blocks[0]))
        #expect(token?.pubkey == agent)
        #expect(token?.isAgent == true)
    }

    @Test("a mention of a person does not")
    func personMentionIsNotFlagged() {
        let resolver = MessageMentionResolver(
            mentions: [MentionRef(pubkey: person, displayName: "Ada")],
            channels: .empty,
            selfPubkey: nil,
            agentPubkeys: [agent]
        )
        let blocks = RichTextEntities.resolve(RichTextParser.parse("ping @Ada"), with: resolver)
        #expect(RichTextProbe.firstMention(RichTextProbe.inline(of: blocks[0]))?.isAgent == false)
    }

    @Test("the flag survives the first-name alias, which is a second registration of the same key")
    func aliasCarriesTheFlag() {
        let resolver = MessageMentionResolver(
            mentions: [MentionRef(pubkey: agent, displayName: "Bumble Bee")],
            channels: .empty,
            selfPubkey: nil,
            agentPubkeys: [agent]
        )
        #expect(resolver.mention(forName: "Bumble Bee")?.isAgent == true)
        #expect(resolver.mention(forName: "Bumble")?.isAgent == true)
    }

    @Test("an unflagged mention defaults to a person, so every pre-existing call site still means one")
    func defaultsToPerson() {
        #expect(MentionToken(pubkey: "PK", isSelf: false).isAgent == false)
        #expect(MentionMatch(pubkey: "PK", isSelf: false).isAgent == false)
    }

    // MARK: - The memo key

    @Test("becoming an agent changes the resolver identity, so a cached render is not reused")
    func identityTracksTheAgentFlag() {
        func resolver(agents: Set<String>) -> MessageMentionResolver {
            MessageMentionResolver(
                mentions: [MentionRef(pubkey: agent, displayName: "Bumble")],
                channels: .empty,
                selfPubkey: nil,
                agentPubkeys: agents
            )
        }
        // The message, the channel map and the identity are all unchanged here. The
        // roster promotion is the *only* difference, and it is the one a memo keyed
        // without it would miss — serving the render made before the glyph existed.
        #expect(resolver(agents: []).identity != resolver(agents: [agent]).identity)
    }

    @Test("an agent this message does not mention leaves the identity alone")
    func unmentionedAgentDoesNotRekey() {
        func resolver(agents: Set<String>) -> MessageMentionResolver {
            MessageMentionResolver(
                mentions: [MentionRef(pubkey: person, displayName: "Ada")],
                channels: .empty,
                selfPubkey: nil,
                agentPubkeys: agents
            )
        }
        // Otherwise every cached render in the app is thrown away whenever any agent
        // anywhere joins a channel.
        #expect(resolver(agents: []).identity == resolver(agents: [agent]).identity)
    }

    // MARK: - Geometry

    @Test("the glyph is drawn at lucide's 0.95em, recovered from the run rather than assumed")
    func glyphIsNineteenTwentiethsOfAnEm() {
        // An Inter-like line: ascent + descent is ~1.21em, which is what the frame
        // divides back out. 51pt of line box is the app's body text at @3x.
        let ascent: CGFloat = 41
        let descent: CGFloat = 10
        let rect = CGRect(x: 0, y: 0, width: 30, height: ascent + descent)
        let frame = AgentGlyph.frame(in: rect, ascent: ascent, descent: descent)
        let em = (ascent + descent) / 1.21
        #expect(abs(frame.width - em * AgentGlyph.emScale) < 0.01)
        #expect(frame.width == frame.height)
    }

    @Test("it is centred on the run horizontally and sits above the baseline vertically")
    func glyphSitsOnTheText() {
        let ascent: CGFloat = 41
        let descent: CGFloat = 10
        let rect = CGRect(x: 100, y: 200, width: 30, height: ascent + descent)
        let frame = AgentGlyph.frame(in: rect, ascent: ascent, descent: descent)
        #expect(abs(frame.midX - rect.midX) < 0.01)
        // Not centred in the typographic box: that box hangs a descender's worth below
        // the letters, and centring in it draws the bot visibly low against the name.
        #expect(frame.midY < rect.midY)
        let baseline = rect.minY + ascent
        #expect(frame.midY < baseline)
    }

    @Test("the stroke scales with the glyph, so the eyes stay dots at every text size")
    func strokeScales() {
        // lucide's stroke is 2 of 24. A fixed width would swallow the two-unit eye
        // segments at small sizes and hairline the whole icon at large ones.
        #expect(abs(AgentGlyph.strokeStyle(side: 24).lineWidth - 2) < 0.001)
        #expect(abs(AgentGlyph.strokeStyle(side: 48).lineWidth - 4) < 0.001)
        #expect(AgentGlyph.strokeStyle(side: 24).lineCap == .round)
        #expect(AgentGlyph.strokeStyle(side: 24).lineJoin == .round)
    }

    @Test("the path fills the view box it is given")
    func pathFitsItsBox() {
        // Bounded by lucide's own drawing: the ears reach x=2 and x=22 of 24, the head
        // starts at y=4 and the face ends at y=20. Asserting the *ink* rather than the
        // box is what would catch a scale applied to the wrong origin.
        let box = CGRect(x: 10, y: 20, width: 24, height: 24)
        let ink = AgentGlyph.path(in: box).boundingRect
        #expect(abs(ink.minX - 12) < 0.01)
        #expect(abs(ink.maxX - 32) < 0.01)
        #expect(abs(ink.minY - 24) < 0.01)
        #expect(abs(ink.maxY - 40) < 0.01)
    }
}
