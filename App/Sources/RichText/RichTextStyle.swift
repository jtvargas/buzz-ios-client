import SwiftUI

/// The one place the entity tokens turn into pixels — Slack-mobile *tinted text*,
/// not a filled pill: accent-coloured, medium-weight inline text that stays a single
/// selectable, Dynamic-Type-correct `Text` per block. Self-mentions get a stronger
/// treatment (bolder). The AST carries only identity; this maps it to colour + weight
/// at draw time, so the styling lives in exactly one tweakable spot.
enum RichTextStyle {
    /// The token tint — the app's global accent (honey amber), the same colour that
    /// tints buttons and the unread pill.
    static let tint = Color.hiveAccent

    /// A plain (non-self) mention: medium weight, distinct from body text and links.
    static let mentionWeight: Font.Weight = .medium
    /// A self-mention: bolder, so a message *to you* reads at a glance.
    static let selfMentionWeight: Font.Weight = .semibold
    /// A `#`-channel reference: medium, matching a plain mention.
    static let channelWeight: Font.Weight = .medium
    /// A web/email/internal link: medium, matching a plain mention.
    static let linkWeight: Font.Weight = .medium

    /// The one named Inter face a styled run asks SwiftUI to draw. Keeping this as data makes
    /// the composition rule testable at ``HiveTypography/variableFont(_:size:weight:)`` — the
    /// last point at which a missing or substituted face is visible.
    struct FontRequest: Equatable {
        let weight: Font.Weight
        let italic: Bool

        var postScriptName: HiveTypography.PostScriptName {
            italic ? .italic : .regular
        }
    }

    /// The horizontal indent applied per nested-list level.
    static let nestedIndent: CGFloat = 16

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
    /// (so it still scales with Dynamic Type), every inline-code span gains the mobile
    /// client's bold prose treatment and highlight, and plain runs inherit the view's
    /// environment font and colour untouched.
    ///
    /// # Why `base` is a text style and not a `Font`
    ///
    /// A `Font.weight(_:)` modifier asks for a trait after its face was built. The app
    /// resolves Inter's `wght` axis while building the font instead, so taking the
    /// *style* here keeps every mention, channel reference, and link on a real weight.
    ///
    /// Emphasis the parse stage recorded as intent — struck, underlined, and code —
    /// is stated as attributes first, by ``emphasised(_:base:)``, for the same reason:
    /// what `Text` resolves from an intent alone is not enough once the family is custom.
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
        // Preserve parse intent before `emphasised` removes the trait bits. Entity styling
        // runs after emphasis to add its colour/link, but it must build the same named face
        // so `**@Ada**` does not silently fall back to the entity's medium weight.
        let runs = attributed.runs.map { ($0.range, $0.mention, $0.channel, $0.link, $0.inlinePresentationIntent) }
        var output = emphasised(attributed, base: base)
        for (range, mention, channel, link, intent) in runs {
            if let mention {
                output[range].foregroundColor = tint
                output[range].font = font(
                    base: base,
                    intent: intent,
                    entityWeight: mention.isSelf ? selfMentionWeight : mentionWeight
                )
                output[range].link = interactive
                    ? mention.pubkey.flatMap { RichTextTarget.user(pubkey: $0).url }
                    : nil
            } else if let channel {
                output[range].foregroundColor = tint
                output[range].font = font(base: base, intent: intent, entityWeight: channelWeight)
                output[range].link = interactive
                    ? channel.channelID.flatMap { RichTextTarget.channel(id: $0).url }
                    : nil
            } else if link != nil {
                // A web, email, or internal link: the same treatment a mention gets,
                // so interactive text reads as one visual language rather than two.
                output[range].foregroundColor = tint
                output[range].font = font(base: base, intent: intent, entityWeight: linkWeight)
                if !interactive { output[range].link = nil }
            }
        }
        return interactive ? spaced(output) : output
    }

    /// Turns the emphasis the *parse* stage recorded as intent into attributes a
    /// SwiftUI `Text` is guaranteed to draw: named Inter faces for emphasis and inline code,
    /// a highlighted code span, a struck run, and a `<u>` underline. Naming the face while it
    /// is built preserves Dynamic Type and prevents a trait request from substituting it.
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
            if let request = fontRequest(for: intent) {
                output[range].font = .hive(base, weight: request.weight, italic: request.italic)
            }
            if intent.contains(.code) {
                output[range].backgroundColor = inlineCodeBackground
            }
            let remainingIntent = intent.subtracting([.emphasized, .stronglyEmphasized, .code])
            output[range].inlinePresentationIntent = remainingIntent.isEmpty ? nil : remainingIntent
        }
        return output
    }

    /// Mobile uses bold body text with a secondary-label wash for inline code. The semantic
    /// colour resolves with the active appearance, unlike a fixed light-mode grey.
    static let inlineCodeBackground = Color(uiColor: .secondaryLabel).opacity(0.2)

    /// Resolves all intersecting inline and entity treatment in one place. Entity styling runs
    /// after emphasis to add colour and links, so it must reapply the same composed request.
    /// Strong emphasis upgrades medium entity text; inline code uses the same bold Inter
    /// body face as the mobile client.
    static func fontRequest(
        for intent: InlinePresentationIntent?,
        entityWeight: Font.Weight? = nil
    ) -> FontRequest? {
        let code = intent?.contains(.code) == true
        let strong = intent?.contains(.stronglyEmphasized) == true
        let italic = intent?.contains(.emphasized) == true
        guard code || strong || italic || entityWeight != nil else { return nil }

        let emphasisWeight: Font.Weight
        if code || strong {
            emphasisWeight = .bold
        } else {
            emphasisWeight = .regular
        }
        return FontRequest(
            weight: heavier(of: emphasisWeight, and: entityWeight ?? .regular),
            italic: italic
        )
    }

    private static func heavier(of left: Font.Weight, and right: Font.Weight) -> Font.Weight {
        left.variableAxisValue >= right.variableAxisValue ? left : right
    }

    private static func font(
        base: Font.TextStyle,
        intent: InlinePresentationIntent?,
        entityWeight: Font.Weight
    ) -> Font {
        let request = fontRequest(for: intent, entityWeight: entityWeight)
            ?? FontRequest(weight: entityWeight, italic: false)
        return .hive(base, weight: request.weight, italic: request.italic)
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

private extension Font.Weight {
    var variableAxisValue: CGFloat {
        switch self {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}
