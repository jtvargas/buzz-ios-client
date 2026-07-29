import CoreText
@testable import Hive
import SwiftUI
import Testing
import UIKit

@Suite("Typography")
struct TypographyTests {
    @Test("the upstream Inter and GeistMono faces register")
    func facesRegister() {
        for face in HiveTypography.PostScriptName.allCases {
            #expect(UIFont(name: face.rawValue, size: 17) != nil, "\(face.rawValue) did not register")
        }
        #expect(HiveTypography.isAvailable)
        #expect(HiveTypography.isMonoAvailable)
        #expect(UIFont.familyNames.contains(HiveTypography.familyName))
        #expect(UIFont.familyNames.contains(HiveTypography.monoFamilyName))
    }

    @Test("UIAppFonts lists the four upstream font files")
    func appFontsMatchTheUpstreamAssets() throws {
        let listed = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        #expect(Set(listed) == [
            "InterVariable.ttf", "InterVariable-Italic.ttf",
            "GeistMono-Variable.ttf", "GeistMono-Italic-Variable.ttf",
        ])
        for file in listed {
            let name = (file as NSString).deletingPathExtension
            #expect(Bundle.main.url(forResource: name, withExtension: "ttf") != nil, "\(file) is not in the bundle")
        }
    }

    @Test("the availability probe rejects an unknown font")
    func unknownFaceIsNil() {
        #expect(UIFont(name: "Inter-DoesNotExist", size: 17) == nil)
        #expect(UIFont(name: HiveTypography.PostScriptName.regular.rawValue + "X", size: 17) == nil)
    }

    @Test("the probe answers per face, not per family")
    func availabilityIsAskedPerFace() {
        // The guard in `variableFont` used to ask whether the *regular* member had
        // registered and then name the italic one. That is not a check: a descriptor
        // built from an unbacked name still resolves to a substitute, so a missing
        // italic would have been drawn as a substitute rather than caught.
        for face in HiveTypography.PostScriptName.allCases {
            #expect(HiveTypography.isRegistered(face), "\(face.rawValue) did not register")
        }
    }

    @Test("italic resolves to the shipped Inter italic rather than a synthesised slant")
    func italicResolvesToTheShippedFace() throws {
        // Prose italic is the one axis nothing in `HiveTypography` selects:
        // `PostScriptName.italic` is never passed to `variableFont`, because
        // `RichTextStyle` deliberately leaves `.emphasized` to `Text` so Dynamic Type
        // keeps working. That delegation is only safe while the family resolves its own
        // italic member — the alternative is a faux oblique sheared off the regular face,
        // which is the parity gap the typeface change exists to close.
        //
        // Asked at the descriptor level, which is the route a trait takes. It is not
        // `Text` itself; nothing here renders one.
        let regular = UIFontDescriptor(name: HiveTypography.PostScriptName.regular.rawValue, size: 17)
        let italic = try #require(regular.withSymbolicTraits(.traitItalic))
        let resolved = UIFont(descriptor: italic, size: 17)
        #expect(
            resolved.familyName == HiveTypography.familyName,
            "italic left the family: \(resolved.familyName)"
        )
        #expect(
            resolved.fontName != HiveTypography.PostScriptName.regular.rawValue,
            "italic resolved to the regular face, so the slant is synthesised: \(resolved.fontName)"
        )
    }

    @Test(
        "every face resolves into its own family rather than a system substitute",
        arguments: HiveTypography.PostScriptName.allCases
    )
    func facesResolveRatherThanSubstitute(face: HiveTypography.PostScriptName) throws {
        // `facesRegister` proves the four files loaded. This proves that what the app
        // then *builds* is one of them, which is a different question: a descriptor
        // named after a face nothing backs resolves to a substitute rather than nil, so
        // the `?? .systemFont` arm never fires and the fallback is silent by
        // construction — clean build, green suite, wrong letters.
        let mono = face == .mono || face == .monoItalic
        let resolved = try #require(HiveTypography.variableFont(face, size: 13, weight: .regular))
        #expect(
            resolved.familyName == (mono ? HiveTypography.monoFamilyName : HiveTypography.familyName),
            "\(face.rawValue) resolved into \(resolved.familyName) as \(resolved.fontName)"
        )
    }

    @Test("the italic faces are their own resolution, not the upright one reused")
    func italicFacesAreDistinct() throws {
        // The family assertion above cannot separate the two members of a family, and
        // an italic that quietly resolves to its upright sibling is drawn as a
        // synthesised slant — the parity gap the typeface change exists to close.
        func resolve(_ name: HiveTypography.PostScriptName) throws -> String {
            try #require(HiveTypography.variableFont(name, size: 13, weight: .regular)).fontName
        }
        #expect(try resolve(.regular) != resolve(.italic))
        #expect(try resolve(.mono) != resolve(.monoItalic))
    }

    @Test("the routes code blocks and avatars draw with keep their face")
    func shippedFixedSizeRoutesKeepTheirFace() {
        // These are the routes nothing asserted a face on before. `MessageTypographyTests`
        // compares `Font` to `Font` with both sides built by the same helper, which proves
        // the helpers agree with themselves and would keep passing with the system
        // monospace font on screen. `RichCodeBlock` draws every code block through
        // `.hiveMono(fixedSize:)` and its comments through the italic arm of the same call.
        //
        // What this does not prove: that each helper passes the *right* name to
        // `variableFont`. That is a read of five call sites, not a test.
        for italic in [false, true] {
            let scaled = HiveTypography.monoUIFont(.body, weight: .regular, italic: italic)
            #expect(
                scaled.familyName == HiveTypography.monoFamilyName,
                "mono \(italic ? "italic" : "upright") resolved into \(scaled.familyName)"
            )
        }
        let drawing = HiveTypography.drawingFont(fixedSize: 30)
        #expect(
            drawing.familyName == HiveTypography.familyName,
            "SVG avatar text resolved into \(drawing.familyName)"
        )
    }

    @Test("the UIKit Inter route scales")
    func uiFontScales() {
        let body = HiveTypography.uiFont(.body)
        let semibold = HiveTypography.uiFont(.body, weight: .semibold)
        // A resolved variation instance does not keep the face's own PostScript
        // name, and what it is renamed to is a CoreText version detail: Xcode 26.2
        // reports "InterVariable", 26.6 reports "InterVariable_opsz110000_wght"
        // (the axis values in 16.16 fixed point — 0x110000 is opsz 17). The face
        // is what has to be asserted, so match its name as a prefix; the system
        // fallback this guards against is ".SFUI-Regular" and fails either way.
        #expect(body.fontName.hasPrefix(HiveTypography.PostScriptName.regular.rawValue))
        #expect(semibold.fontName.hasPrefix(HiveTypography.PostScriptName.regular.rawValue))
        #expect(semibold.pointSize == body.pointSize)
        #expect(body != semibold)
        #expect(variation(body, axis: 0x7767_6874) == 400)
        #expect(variation(semibold, axis: 0x7767_6874) == 600)

        let large = HiveTypography.uiFont(
            .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        #expect(large.pointSize > body.pointSize)
    }

    @Test("Inter uses its optical-size axis")
    func interUsesOpticalSize() {
        let body = HiveTypography.uiFont(.body)
        let heading = HiveTypography.uiFont(.title1)
        #expect(variation(body, axis: 0x6F70_737A) == 17)
        #expect(variation(heading, axis: 0x6F70_737A) == 28)
    }

    private func variation(_ font: UIFont, axis: UInt32) -> CGFloat? {
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let values = font.fontDescriptor.object(forKey: key) as? [NSNumber: NSNumber]
        return values?[NSNumber(value: axis)].map { CGFloat($0.doubleValue) }
    }
}

@Suite("Typography in messages")
struct MessageTypographyTests {
    @Test("an entity run resolves its requested Inter weight")
    func entityRunNamesItsCut() throws {
        var attributed = AttributedString("@ada")
        attributed.mention = MentionToken(pubkey: String(repeating: "a", count: 64), isSelf: false)
        let styled = RichTextStyle.styled(attributed, base: .body)

        let run = try #require(styled.runs.first)
        #expect(run.font == .hive(.body, weight: RichTextStyle.mentionWeight))
        #expect(run.foregroundColor == RichTextStyle.tint)
    }

    @Test("a self mention requests a stronger weight")
    func selfMentionIsHeavier() {
        #expect(RichTextStyle.selfMentionWeight != RichTextStyle.mentionWeight)
    }

    @Test("an inline code span uses GeistMono")
    func inlineCodeStaysMonospaced() throws {
        var code = AttributedString("--flag")
        code.inlinePresentationIntent = .code
        var attributed = AttributedString("run ")
        attributed.append(code)

        let styled = RichTextStyle.styled(attributed, base: .body)
        let codeRun = try #require(styled.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(codeRun.font == .hiveMono(.body))
        let prose = try #require(styled.runs.first { $0.inlinePresentationIntent == nil })
        #expect(prose.font == nil)
    }

    @Test("inline treatments keep the block text style", arguments: [
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
