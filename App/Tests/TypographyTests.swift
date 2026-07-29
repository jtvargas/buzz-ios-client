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

    @Test("the UIKit Inter route scales")
    func uiFontScales() {
        let body = HiveTypography.uiFont(.body)
        let semibold = HiveTypography.uiFont(.body, weight: .semibold)
        #expect(body.fontName == HiveTypography.PostScriptName.regular.rawValue)
        #expect(semibold.fontName == HiveTypography.PostScriptName.regular.rawValue)
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
        return values?[NSNumber(value: axis)]?.doubleValue
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
