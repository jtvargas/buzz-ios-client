import CoreText
import SwiftUI
import UIKit

/// The mobile client's typography: Inter for prose and GeistMono for code.
///
/// Both families ship as variable fonts. SwiftUI's `Font.weight(_:)` cannot be the
/// weight mechanism here: it applies a trait after the face has been built, and that
/// was silently ignored by the former static family. Each helper instead builds a
/// `UIFontDescriptor` with Inter or GeistMono's `wght` axis set explicitly, then
/// hands that already-resolved face to SwiftUI.
enum HiveTypography {
    static let familyName = "Inter Variable"
    static let monoFamilyName = "Geist Mono"

    enum PostScriptName: String, CaseIterable {
        case regular = "InterVariable"
        case italic = "InterVariableItalic"
        case mono = "GeistMono-Regular"
        case monoItalic = "GeistMono-Italic"
    }

    static let isAvailable: Bool = isRegistered(.regular)
    static let isMonoAvailable: Bool = isRegistered(.mono)

    /// Whether *this* face registered — asked per face, never per family.
    ///
    /// A descriptor built from a PostScript name nothing backs does not fail:
    /// `UIFont(descriptor:size:)` hands back a resolved substitute rather than nil, so
    /// the `?? .systemFont` arm in ``variableFont(_:size:weight:)`` can never see a face
    /// that is missing. Probing the regular member and then naming its italic sibling
    /// would leave the app drawing a substitute with a clean build and green tests.
    ///
    /// Answered from a table built once. ``variableFont(_:size:weight:)`` guards on this
    /// on the way to every font the app builds, which is every view body that names one;
    /// registration is fixed at launch by `UIAppFonts`, so there is nothing to re-ask.
    static func isRegistered(_ name: PostScriptName) -> Bool {
        registrations[name] ?? false
    }

    private static let registrations: [PostScriptName: Bool] = Dictionary(
        uniqueKeysWithValues: PostScriptName.allCases.map { ($0, UIFont(name: $0.rawValue, size: 12) != nil) }
    )

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font(uiFont(style.uiKit, weight: weight))
    }

    static func font(
        fixedSize: CGFloat,
        relativeTo style: Font.TextStyle,
        weight: Font.Weight = .regular
    ) -> Font {
        Font(uiFont(style.uiKit, weight: weight, fixedSize: fixedSize))
    }

    static func font(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        let font = variableFont(PostScriptName.regular, size: fixedSize, weight: weight)
            ?? .systemFont(ofSize: fixedSize, weight: weight.uiKit)
        return Font(font)
    }

    static func monoFont(
        _ style: Font.TextStyle,
        weight: Font.Weight = .regular,
        italic: Bool = false
    ) -> Font {
        Font(monoUIFont(style.uiKit, weight: weight, italic: italic))
    }

    static func monoFont(fixedSize: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let name: PostScriptName = italic ? .monoItalic : .mono
        let font = variableFont(name, size: fixedSize, weight: weight)
            ?? .monospacedSystemFont(ofSize: fixedSize, weight: weight.uiKit)
        return Font(font)
    }

    static func size(of style: Font.TextStyle) -> CGFloat {
        defaultSizes[style] ?? 17
    }

    private static let defaultSizes: [Font.TextStyle: CGFloat] = [
        .largeTitle: 34,
        .title: 28,
        .title2: 22,
        .title3: 20,
        .headline: 17,
        .body: 17,
        .callout: 16,
        .subheadline: 15,
        .footnote: 13,
        .caption: 12,
        .caption2: 11,
    ]

    /// UIKit chrome still renders its own text, so it receives the same resolved Inter
    /// face as SwiftUI. `UIFontMetrics` supplies Dynamic Type scaling at render time.
    static func uiFont(
        _ style: UIFont.TextStyle,
        weight: Font.Weight = .regular,
        fixedSize: CGFloat? = nil,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        let size = fixedSize ?? UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let base = variableFont(PostScriptName.regular, size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: weight.uiKit)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }

    /// SVG text has its own authored size, so it needs Inter without Dynamic Type scaling.
    static func drawingFont(fixedSize: CGFloat) -> UIFont {
        variableFont(.regular, size: fixedSize, weight: .regular)
            ?? .systemFont(ofSize: fixedSize, weight: .regular)
    }

    /// Internal rather than private for the same reason as ``variableFont(_:size:weight:)``:
    /// ``monoFont(_:weight:italic:)`` hands back a `Font`, which cannot be asked its face,
    /// so this is the only place the mono route's resolution is observable.
    static func monoUIFont(
        _ style: UIFont.TextStyle,
        weight: Font.Weight,
        italic: Bool
    ) -> UIFont {
        let size = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let name: PostScriptName = italic ? .monoItalic : .mono
        let base = variableFont(name, size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight.uiKit)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// Internal rather than private so a test can assert the *resolved* face.
    ///
    /// Every helper above funnels through here, and registration and resolution are
    /// separate questions: ``isRegistered(_:)`` says the file loaded, this says which
    /// letters come back. The `fixedSize` helpers hand SwiftUI a `Font`, which cannot be
    /// asked its face, so this is the last point at which a substitute is still visible.
    static func variableFont(_ name: PostScriptName, size: CGFloat, weight: Font.Weight) -> UIFont? {
        guard isRegistered(name) else { return nil }
        var variations: [NSNumber: CGFloat] = [
            Self.weightAxis: variableWeight(for: weight), // `wght`
        ]
        if name == .regular || name == .italic {
            variations[Self.opticalSizeAxis] = min(max(size, 14), 32) // `opsz`
        }
        let descriptor = UIFontDescriptor(name: name.rawValue, size: size)
            .addingAttributes([Self.variationAttribute: variations])
        return UIFont(descriptor: descriptor, size: size)
    }

    private static let variationAttribute = UIFontDescriptor.AttributeName(rawValue:
        kCTFontVariationAttribute as String
    )
    private static let weightAxis = NSNumber(value: 0x7767_6874)
    private static let opticalSizeAxis = NSNumber(value: 0x6F70_737A)

    private static func variableWeight(for weight: Font.Weight) -> CGFloat {
        switch weight {
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

extension HiveTypography {
    @MainActor
    static func applyUIKitAppearance() {
        guard isAvailable else { return }

        let navigation = UINavigationBarAppearance()
        navigation.configureWithDefaultBackground()
        navigation.titleTextAttributes = [.font: uiFont(.headline, weight: .semibold)]
        navigation.largeTitleTextAttributes = [.font: uiFont(.largeTitle, weight: .bold)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        let title = [NSAttributedString.Key.font: uiFont(.caption2, weight: .medium)]
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = title
            item.selected.titleTextAttributes = title
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension Font.Weight {
    var uiKit: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension Font {
    static func hive(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        HiveTypography.font(style, weight: weight)
    }

    static func hive(fixedSize: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        HiveTypography.font(fixedSize: fixedSize, relativeTo: style, weight: weight)
    }

    static func hive(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        HiveTypography.font(fixedSize: fixedSize, weight: weight)
    }

    static func hiveMono(_ style: Font.TextStyle, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        HiveTypography.monoFont(style, weight: weight, italic: italic)
    }

    static func hiveMono(fixedSize: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        HiveTypography.monoFont(fixedSize: fixedSize, weight: weight, italic: italic)
    }

    static func hiveSymbol(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, weight: weight)
    }

    static func hiveSymbol(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: fixedSize, weight: weight)
    }
}
