@testable import Hive
import SwiftUI
import Testing
import UIKit

/// The typeface, asserted where it can be: the faces that must be in the bundle, the
/// weight map, the size table, and the one CoreText behaviour the whole design rests
/// on.
///
/// What a `Font` *draws* is not readable from a test — `Font` has no public
/// introspection — so these assert the `UIFont` layer underneath it, which is what
/// `Font.custom(_:size:relativeTo:)` resolves against.
@Suite("Typography")
struct TypographyTests {
    /// Every cut named in `UIAppFonts` actually registered. A face that failed to
    /// copy into the bundle is invisible at runtime — `Font.custom` falls back to
    /// San Francisco per call and says nothing — so this is the check that a
    /// half-bundled family cannot ship.
    @Test("every bundled face registers")
    func facesRegister() {
        for face in [
            HiveTypography.PostScriptName.regular, .italic, .medium,
            .semibold, .bold, .boldItalic,
        ] {
            #expect(UIFont(name: face.rawValue, size: 17) != nil, "\(face.rawValue) did not register")
        }
        #expect(HiveTypography.isAvailable)
        #expect(UIFont.familyNames.contains(HiveTypography.familyName))
    }

    /// `UIAppFonts`, the files in the bundle, and ``HiveTypography/PostScriptName`` all
    /// describe the same six faces.
    ///
    /// Three lists that have to agree and no compiler that checks them: a face can be
    /// dropped from the plist, a file can fail to copy, or a PostScript name in the enum
    /// can be spelled the way the *file* is named rather than the way the font's own name
    /// table is — and all three fail the same way, which is Lato for most of the app and
    /// San Francisco for one weight, on a device, with nothing logged. Read out of the
    /// host app's bundle rather than hard-coded, so adding a seventh cut cannot half-land.
    @Test("UIAppFonts, the bundled files, and the enum agree")
    func appFontsMatchTheEnum() throws {
        let listed = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        #expect(listed.count == 6)

        let named = Set([
            HiveTypography.PostScriptName.regular, .italic, .medium, .semibold, .bold, .boldItalic,
        ].map(\.rawValue))
        for file in listed {
            let name = (file as NSString).deletingPathExtension
            #expect(Bundle.main.url(forResource: name, withExtension: "ttf") != nil, "\(file) is not in the bundle")
            // Lato's filenames happen to be its PostScript names; the point of the check
            // is that they still are, since that is the assumption the enum encodes.
            #expect(named.contains(name), "\(name) is bundled but no `PostScriptName` case names it")
            #expect(UIFont(name: name, size: 17)?.fontName == name)
        }
        for name in named {
            #expect(listed.contains("\(name).ttf"), "\(name) is named in code but not in UIAppFonts")
        }
    }

    /// The other half of that check, and the one that gives it meaning: `UIFont(name:)`
    /// reports a name it does not know as `nil` rather than substituting something.
    ///
    /// Without this, ``HiveTypography/isAvailable`` could be a tautology — a probe that
    /// answers `true` whatever is in the bundle, because CoreText handed back Helvetica
    /// for a name nobody registered. A wrong PostScript name is the classic way a bundled
    /// family ships broken and says nothing, so the detector is asserted, not assumed.
    @Test("an unregistered face is nil, so the availability probe can fail")
    func unknownFaceIsNil() {
        #expect(UIFont(name: "Lato-DoesNotExist", size: 17) == nil)
        #expect(UIFont(name: HiveTypography.PostScriptName.regular.rawValue + "X", size: 17) == nil)
    }

    /// The weight map. Lato's unbundled cuts collapse onto the nearest one carried,
    /// and the four the app actually uses each get their own face.
    @Test("weights map to the drawn cut")
    func weightMap() {
        #expect(HiveTypography.face(for: .regular) == .regular)
        #expect(HiveTypography.face(for: .light) == .regular)
        #expect(HiveTypography.face(for: .medium) == .medium)
        #expect(HiveTypography.face(for: .semibold) == .semibold)
        #expect(HiveTypography.face(for: .bold) == .bold)
        #expect(HiveTypography.face(for: .black) == .bold)
    }

    /// The size table against the system's own numbers.
    ///
    /// ``HiveTypography/size(of:)`` is a literal table because the lookup it replaces
    /// allocates on a path that runs once per `Text` in a scrolling list. This is what
    /// stops the table drifting from the sizes iOS actually uses: if a release moves
    /// one, this goes red rather than the app quietly rendering a text style at the
    /// wrong base size.
    @Test("the size table matches the system's default sizes", arguments: [
        (Font.TextStyle.largeTitle, UIFont.TextStyle.largeTitle),
        (.title, .title1),
        (.title2, .title2),
        (.title3, .title3),
        (.headline, .headline),
        (.body, .body),
        (.callout, .callout),
        (.subheadline, .subheadline),
        (.footnote, .footnote),
        (.caption, .caption1),
        (.caption2, .caption2),
    ])
    func sizeTable(style: Font.TextStyle, uiStyle: UIFont.TextStyle) {
        let system = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: uiStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let table = HiveTypography.size(of: style)
        #expect(table == system, "\(uiStyle.rawValue) is \(system), table says \(table)")
    }

    /// The measured fact `HiveTypography` is built on: a *symbolic* trait resolves
    /// inside the Lato family, so markdown emphasis in a message draws the real cut
    /// rather than a synthesised slant or smear. Nothing in the app arranges this —
    /// CoreText does it — which is exactly why it is asserted rather than assumed.
    @Test("emphasis resolves to a real Lato cut")
    func symbolicTraitsResolveWithinTheFamily() {
        func resolved(_ base: HiveTypography.PostScriptName, _ traits: UIFontDescriptor.SymbolicTraits) -> String? {
            UIFontDescriptor(name: base.rawValue, size: 17)
                .withSymbolicTraits(traits)
                .map { UIFont(descriptor: $0, size: 17).fontName }
        }
        #expect(resolved(.regular, .traitItalic) == HiveTypography.PostScriptName.italic.rawValue)
        #expect(resolved(.regular, .traitBold) == HiveTypography.PostScriptName.bold.rawValue)
        #expect(resolved(.regular, [.traitBold, .traitItalic]) == HiveTypography.PostScriptName.boldItalic.rawValue)
    }

    /// The other half of that measurement, and the reason every weight names a face:
    /// the *weight* trait does not resolve on a static family. Asking `Lato-Regular`
    /// for semibold returns `Lato-Regular`. If a future Lato ships as a variable font
    /// this goes red, and `face(for:)` can be deleted.
    @Test("the weight trait does not resolve on a static family")
    func weightTraitDoesNotResolve() {
        let descriptor = UIFontDescriptor(name: HiveTypography.PostScriptName.regular.rawValue, size: 17)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        #expect(UIFont(descriptor: descriptor, size: 17).fontName == HiveTypography.PostScriptName.regular.rawValue)
    }

    /// The UIKit path: Lato, at the style's own size, and scaling — a `UIFont` does
    /// not scale itself, so a missing `UIFontMetrics` here would freeze the navigation
    /// bar and tab bar at the default content size while the rest of the app moved.
    @Test("the UIKit font is Lato and scales")
    func uiFontScales() {
        let body = HiveTypography.uiFont(.body)
        #expect(body.fontName == HiveTypography.PostScriptName.regular.rawValue)
        let semibold = HiveTypography.uiFont(.body, weight: .semibold)
        #expect(semibold.fontName == HiveTypography.PostScriptName.semibold.rawValue)
        // The composer measures its own six-line ceiling off this, so the two cuts have
        // to agree about the size a mention is inserted at.
        #expect(semibold.pointSize == body.pointSize)

        let large = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        #expect(large.pointSize > body.pointSize)
    }

    /// Lato's figures are tabular in every bundled cut, which is why the app's six
    /// `.monospacedDigit()` call sites were left alone rather than being folded into the
    /// font: the property they exist to guarantee — a count or a clock that changes
    /// without reflowing the label around it — is already true of the face.
    ///
    /// Asserted rather than trusted because it is a property of the *files*, and a future
    /// Lato that shipped proportional figures would break a still pill in a way nobody
    /// would think to look at the font for.
    @Test("Lato's digits all advance the same width", arguments: [
        HiveTypography.PostScriptName.regular, .medium, .semibold, .bold,
    ])
    func digitsAreTabular(face: HiveTypography.PostScriptName) throws {
        let font = try #require(UIFont(name: face.rawValue, size: 17))
        let widths = (0 ... 9).map { digit in
            ("\(digit)" as NSString).size(withAttributes: [.font: font]).width
        }
        #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1, "\(face.rawValue): \(widths)")
    }
}

// MARK: - What the message renderer does with it

/// The two things ``RichTextStyle`` has to name for itself, because both are traits the
/// app's typeface drops.
///
/// Neither failure is visible from a screenshot at a glance and neither raises anything:
/// a mention loses its weight but keeps its tint, and an inline code span keeps its text
/// but stops being a code span. So both are pinned here, at the value the renderer
/// actually writes.
@Suite("Typography in messages")
struct MessageTypographyTests {
    /// A resolved mention is set in a *named* cut, not in `base.weight(…)`.
    @Test("an entity run names a Lato cut rather than asking for a weight")
    func entityRunNamesItsCut() throws {
        var attributed = AttributedString("@ada")
        attributed.mention = MentionToken(pubkey: String(repeating: "a", count: 64), isSelf: false)
        let styled = RichTextStyle.styled(attributed, base: .body)

        let run = try #require(styled.runs.first)
        #expect(run.font == .hive(.body, weight: RichTextStyle.mentionWeight))
        #expect(run.foregroundColor == RichTextStyle.tint)
    }

    /// A self-mention is heavier than a plain one — the distinction the whole treatment
    /// exists for, and the one a dropped weight trait erases.
    @Test("a self-mention resolves to a different cut from a plain one")
    func selfMentionIsHeavier() {
        #expect(RichTextStyle.selfMentionWeight != RichTextStyle.mentionWeight)
        #expect(
            HiveTypography.face(for: RichTextStyle.selfMentionWeight)
                != HiveTypography.face(for: RichTextStyle.mentionWeight)
        )
    }

    /// An inline code span is monospaced, and is monospaced because the renderer said so.
    ///
    /// `Text` would otherwise resolve `inlinePresentationIntent.code` by asking the run's
    /// font for a fixed-width member of its own family. Lato has none, so on a Lato base
    /// that request is dropped and `` `--flag` `` sets as ordinary prose.
    @Test("an inline code span stays on the monospaced face")
    func inlineCodeStaysMonospaced() throws {
        var code = AttributedString("--flag")
        code.inlinePresentationIntent = .code
        var attributed = AttributedString("run ")
        attributed.append(code)

        let styled = RichTextStyle.styled(attributed, base: .body)
        let codeRun = try #require(styled.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(codeRun.font == .hiveMono(.body))
        // And the prose beside it is left to inherit, rather than being pinned to anything.
        let prose = try #require(styled.runs.first { $0.inlinePresentationIntent == nil })
        #expect(prose.font == nil)
    }

    /// A code span inside a heading is monospaced *at the heading's size*, and a mention
    /// in one is weighted at the heading's size too — the reason `base` is carried through
    /// as a text style rather than being resolved to a font by the caller.
    @Test("both treatments follow the block's own text style", arguments: [
        Font.TextStyle.title2, .title3, .headline, .subheadline,
    ])
    func treatmentsFollowTheBlockStyle(style: Font.TextStyle) throws {
        var code = AttributedString("let x = 1")
        code.inlinePresentationIntent = .code
        #expect(try #require(RichTextStyle.styled(code, base: style).runs.first).font == .hiveMono(style))

        var mention = AttributedString("@ada")
        mention.mention = MentionToken(pubkey: nil, isSelf: true)
        let styled = RichTextStyle.styled(mention, base: style)
        #expect(
            try #require(styled.runs.first).font
                == .hive(style, weight: RichTextStyle.selfMentionWeight)
        )
    }
}
