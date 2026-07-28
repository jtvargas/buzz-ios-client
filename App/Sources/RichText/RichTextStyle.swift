import SwiftUI

/// The one place the entity tokens turn into pixels — Slack-mobile *tinted text*,
/// not a filled pill: accent-coloured, medium-weight inline text that stays a single
/// selectable, Dynamic-Type-correct `Text` per block. Self-mentions get a stronger
/// treatment (bolder). The AST carries only identity; this maps it to colour + weight
/// at draw time, so the styling lives in exactly one tweakable spot.
enum RichTextStyle {
    /// The token tint — the app's global accent (honey amber), the same colour that
    /// tints buttons and the unread pill.
    static let tint = Color.accentColor

    /// A plain (non-self) mention: medium weight, distinct from body text and links.
    static let mentionWeight: Font.Weight = .medium
    /// A self-mention: bolder, so a message *to you* reads at a glance.
    static let selfMentionWeight: Font.Weight = .semibold
    /// A `#`-channel reference: medium, matching a plain mention.
    static let channelWeight: Font.Weight = .medium
    /// A web/email/internal link: medium, matching a plain mention.
    static let linkWeight: Font.Weight = .medium

    /// The horizontal indent applied per nested-list level.
    static let nestedIndent: CGFloat = 16

    /// The ordinary gap between two blocks of a message. See ``RichTextSpacing`` for
    /// the pairs that want more or less than this.
    static let blockSpacing: CGFloat = 6

    // MARK: - Tables

    /// The widest a single table cell may be laid out before its text wraps inside the
    /// column, at the default text size.
    ///
    /// A cap is not decoration. Inside the table's horizontal scroll view a cell is
    /// offered unlimited width, so without one a cell holding a paragraph becomes a
    /// single line thousands of points long — a column nobody can read and a scroll
    /// nobody can reach the end of. Around a phone's readable measure, so an ordinary
    /// cell never wraps and a pathological one wraps instead of running away.
    static let tableCellMaxWidth: CGFloat = 260

    /// Inset between a table cell's text and its column edges. Generous horizontally
    /// because that gap is doing the work column rules would otherwise do.
    static let tableCellPadding = CGSize(width: 10, height: 6)

    /// The table's own outline and the rules between its rows.
    static let tableBorderRadius: CGFloat = 8

    // MARK: - Rules

    /// The vertical padding around a thematic break, and around the divider drawn under
    /// a level-1 heading.
    static let ruleSpacing: CGFloat = 4

    /// How far the pill is grown beyond the glyphs it sits behind. Horizontal is the
    /// "comfortable padding"; vertical is deliberately small, because a taller pill
    /// starts colliding with the line above in a wrapped paragraph.
    static let pillPadding = CGSize(width: 4, height: 1.5)

    /// The clear space kept between a pill's edge and the text beside it.
    ///
    /// Padding alone cannot produce it: growing the fill past the glyphs does not move
    /// the glyphs, so the pill simply grew *over* its neighbour — a mention sat flush
    /// against the `(` or the word before it. The gap has to come from layout advance,
    /// which is what ``pillAdvance`` inserts.
    static let pillGap: CGFloat = 3

    /// The advance inserted immediately before and immediately after an interactive
    /// range: enough to clear the pill's own padding *and* leave ``pillGap`` of space.
    static var pillAdvance: CGFloat { pillPadding.width + pillGap }

    /// The pill's corner radius, on the small side so a one-word mention does not
    /// read as a capsule button.
    static let pillCornerRadius: CGFloat = 6

    /// The pill fill: the accent at low alpha, lifted in dark mode where the same
    /// alpha over a near-black background is close to invisible. Alpha rather than a
    /// second colour asset so it tints with whatever accent the app is built with.
    static func pillFill(dark: Bool, pressed: Bool) -> Color {
        let alpha: Double = switch (dark, pressed) {
        case (false, false): 0.13
        case (false, true): 0.30
        case (true, false): 0.22
        case (true, true): 0.42
        }
        return tint.opacity(alpha)
    }

    /// Produces the presentation `AttributedString` for one inline: every resolved
    /// mention/channel run gains the accent colour and the right weight *at `base`*
    /// (so it still scales with Dynamic Type), every code span is pinned to the
    /// monospaced face, and plain runs inherit the view's environment font and colour
    /// untouched.
    ///
    /// # Why `base` is a text style and not a `Font`
    ///
    /// It used to be a `Font`, and every weight here was `base.weight(…)`. That is the
    /// one construction the app's typeface cannot honour: Lato is a set of static cuts,
    /// so a weight asked for by trait is dropped and the descriptor hands the regular
    /// face straight back (``HiveTypography``). Every mention, channel reference and
    /// link in every message would have drawn at body weight — no error, no warning,
    /// just the tint doing all the work. Taking the *style* instead means the weight is
    /// named while the font is being built, which is the only way to reach a real cut.
    ///
    /// Emphasis the parse stage recorded as intent — struck, underlined, and code —
    /// is stated as attributes first, by ``emphasised(_:base:)``, for the same reason:
    /// what `Text` resolves from an intent alone is not enough once the family is Lato.
    ///
    /// `interactive` is what separates a message being read from a one-line preview
    /// of one. When it is set, an entity run also gains the `link` that carries its
    /// target (see ``RichTextTarget``) — the only attribute a SwiftUI `Text` will let
    /// a reader press. When it is not, every link is *stripped* instead: a snippet in
    /// the sidebar sits inside a row that is itself a control, and a tappable range
    /// inside it would be a second, competing target for the same tap.
    ///
    /// Ranges are read from the input before any mutation and applied on a copy;
    /// attribute writes preserve indices, so every range stays valid.
    static func styled(
        _ attributed: AttributedString,
        base: Font.TextStyle,
        interactive: Bool = false
    ) -> AttributedString {
        var output = emphasised(attributed, base: base)
        let runs = output.runs.map { ($0.range, $0.mention, $0.channel, $0.link) }
        for (range, mention, channel, link) in runs {
            if let mention {
                output[range].foregroundColor = tint
                output[range].font = .hive(base, weight: mention.isSelf ? selfMentionWeight : mentionWeight)
                output[range].link = interactive
                    ? mention.pubkey.flatMap { RichTextTarget.user(pubkey: $0).url }
                    : nil
            } else if let channel {
                output[range].foregroundColor = tint
                output[range].font = .hive(base, weight: channelWeight)
                output[range].link = interactive
                    ? channel.channelID.flatMap { RichTextTarget.channel(id: $0).url }
                    : nil
            } else if link != nil {
                // A web, email, or internal link: the same treatment a mention gets,
                // so interactive text reads as one visual language rather than two.
                output[range].foregroundColor = tint
                output[range].font = .hive(base, weight: linkWeight)
                if !interactive { output[range].link = nil }
            }
        }
        return interactive ? spaced(output) : output
    }

    /// Turns the emphasis the *parse* stage recorded as intent into attributes a
    /// SwiftUI `Text` is guaranteed to draw: a struck run, a code span's monospaced
    /// face, and a `<u>` underline.
    ///
    /// Bold and italic are deliberately absent. `Text` resolves
    /// `InlinePresentationIntent.stronglyEmphasized` and `.emphasized` itself, and
    /// re-stating them as a `font` here would replace the environment's font instead
    /// of decorating it — which is how a bold word ends up refusing to scale with
    /// Dynamic Type. The three below are stated because leaving them to the intent was
    /// not reliably drawing anything: a strikethrough and a code span rendered
    /// identically to plain body text, so `~~wrong~~` read as a correction that had not
    /// been made.
    ///
    /// A code span's face is composed rather than assigned, so `**`x`**` keeps its
    /// weight: monospaced first, then whatever emphasis the same run also carries.
    ///
    /// The face is *named* rather than reached for with `.monospaced()`. `Text` renders
    /// a `.code` run by asking the run's font for the fixed-width member of its own
    /// family, and the app's family is Lato, which has none — so on a Lato base that
    /// request is dropped exactly the way a weight trait is (``HiveTypography``), and an
    /// inline `` `--flag` `` would have quietly set in proportional Lato in the middle of
    /// a sentence about a command. ``HiveTypography/hiveMono(_:weight:)`` is the system's
    /// monospaced face, which does carry a full weight axis, so the two emphasis
    /// modifiers below still compose onto it.
    private static func emphasised(
        _ attributed: AttributedString,
        base: Font.TextStyle
    ) -> AttributedString {
        var output = attributed
        let runs = output.runs.map { ($0.range, $0.inlinePresentationIntent, $0.underline) }
        for (range, intent, underline) in runs {
            if underline == true {
                output[range].underlineStyle = .single
            }
            guard let intent else { continue }
            if intent.contains(.strikethrough) {
                output[range].strikethroughStyle = .single
            }
            if intent.contains(.code) {
                var font = Font.hiveMono(base)
                if intent.contains(.stronglyEmphasized) { font = font.bold() }
                if intent.contains(.emphasized) { font = font.italic() }
                output[range].font = font
            }
        }
        return output
    }

    /// Holds every pill off the text beside it, by adding ``pillAdvance`` of kerning
    /// before an interactive range and after its last character.
    ///
    /// Kerning rather than padding, and that is measured: a run's typographic bounds
    /// are what the renderer fills, and growing that fill does not push the glyphs
    /// around it — so the only way to open real space beside a pill is to add advance.
    /// The trailing kern lands *inside* the run's bounds (also measured), which is why
    /// the last character is marked with the advance it carries and
    /// ``RichTextEntityRenderer`` takes that width back out of the fill.
    ///
    /// Applied per *segment*, never per run: `@**Ada** Lovelace` is three runs of one
    /// pill, and kerning each one's last character would open gaps inside the mention.
    private static func spaced(_ attributed: AttributedString) -> AttributedString {
        var output = attributed
        for segment in RichTextSegments.segments(of: attributed) where segment.link != nil {
            if segment.range.lowerBound > output.startIndex {
                let before = output.index(beforeCharacter: segment.range.lowerBound)
                output[before ..< segment.range.lowerBound].kern = pillAdvance
            }
            let last = output.index(beforeCharacter: segment.range.upperBound)
            output[last ..< segment.range.upperBound].kern = pillAdvance
        }
        return output
    }
}
