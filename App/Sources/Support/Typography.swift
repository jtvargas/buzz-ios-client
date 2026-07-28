import SwiftUI
import UIKit

/// The app's typeface: Lato, with the system font as the fallback.
///
/// # Why every weight names its own face
///
/// Lato ships as discrete static faces, not a variable font, and CoreText's two
/// matching routes behave differently on it. Measured against the six faces this
/// app bundles:
///
/// - *Symbolic* traits resolve inside the family. `Lato-Regular` + italic gives
///   `Lato-Italic`, + bold gives `Lato-Bold`, + both gives `Lato-BoldItalic`. So
///   markdown emphasis in a message draws the real cut rather than a slanted or
///   smeared imitation, and nothing here has to arrange that.
/// - The *weight* trait does not. `Lato-Regular` asked for medium, semibold, or
///   bold all come back `Lato-Regular` — the descriptor has no weight axis to move
///   along, so the request is dropped. That is why ``face(for:)`` maps a weight to
///   a PostScript name instead of leaving `Font.weight(_:)` to do it: on a custom
///   font that call would silently return the regular cut at every call site the
///   app has for `.medium` and `.semibold`.
///
/// The rule that falls out of the second point is the one to remember, because it is
/// invisible when it is broken: **nothing in the app may reach a weight by modifier.**
/// `.fontWeight(.semibold)`, `.font(.hive(.body)).bold()`, and
/// `AttributedString.font = base.weight(.medium)` are all the dropped trait wearing a
/// different hat — they compiled and ran and drew regular Lato. Every weight is named
/// when the font is built, through ``font(_:weight:)``. Emphasis is the exception and
/// only because it is symbolic: `.italic()`, and markdown's own bold and italic runs,
/// resolve to the real cut.
///
/// # `.monospacedDigit()` is left alone, and is not a third dropped trait
///
/// It looks like one and is not. Measured on the bundled faces: Lato's ten digits all
/// advance 9.86pt at 17pt in regular, medium, semibold and bold alike — the figures are
/// tabular *by design*, so a count under a still pill or a timestamp ticking over cannot
/// reflow the label it sits in. The modifier is kept at all six of its call sites because
/// it is still load-bearing on the fallback path, where the face is San Francisco.
///
/// # Why `Font.custom(_:size:relativeTo:)`
///
/// It is the only construction that keeps scaling after the view is built. A
/// `Font(_: UIFont)` freezes the point size it was made at, so a reader changing
/// Dynamic Type mid-session would move every system-drawn label and leave ours
/// where they were.
///
/// # What deliberately stays on San Francisco
///
/// Four things, and each is a decision rather than a site the sweep missed:
///
/// - **SF Symbols**, through ``SwiftUI/Font/hiveSymbol(_:weight:)``. A symbol is a glyph
///   out of the system's symbol font; Lato has no opinion about it and costs it its
///   weight.
/// - **Monospaced text**, through ``SwiftUI/Font/hiveMono(_:weight:)`` — code blocks and
///   spans, `npub`/`nsec`, the channel id, the pairing SAS. Lato is not a code face.
/// - **Remote SVG avatars** (`SVGAvatarRenderer`), which lay out somebody else's document
///   and resolve colour emoji through the system font's own cascade.
/// - **UIKit's own alerts and action sheets.** A `.alert` or `.confirmationDialog` is
///   drawn by UIKit from strings, with no font seam to reach — there is no appearance
///   proxy for `UIAlertController`'s labels, and the two surfaces the proxies *do* reach
///   are set in ``applyUIKitAppearance()``.
enum HiveTypography {
    /// The bundled family. Registered by `UIAppFonts` at launch, not by us.
    static let familyName = "Lato"

    /// Whether the family actually registered.
    ///
    /// `Font.custom` already falls back to the system font for an unknown name, but
    /// it falls back *per call and silently* — a face that failed to copy into the
    /// bundle would give a mix of Lato and San Francisco rather than one coherent
    /// fallback. Resolved once so the whole app answers the same way.
    static let isAvailable: Bool = UIFont(name: PostScriptName.regular.rawValue, size: 12) != nil

    /// The six cuts the app bundles. Fewer than Lato's nine: the app uses regular,
    /// medium, semibold, and bold, and the two italics are what emphasis resolves to.
    enum PostScriptName: String {
        case regular = "Lato-Regular"
        case italic = "Lato-Italic"
        case medium = "Lato-Medium"
        case semibold = "Lato-SemiBold"
        case bold = "Lato-Bold"
        case boldItalic = "Lato-BoldItalic"
    }

    /// The Lato cut for a requested weight.
    ///
    /// The lighter half of the scale collapses onto regular and the heavier half onto
    /// bold: Lato's Thin, ExtraLight, Light, ExtraBold and Black are not bundled
    /// because nothing in the app asks for them, and 640 KB a face is not worth
    /// carrying for a weight no call site uses.
    static func face(for weight: Font.Weight) -> PostScriptName {
        switch weight {
        case .ultraLight, .thin, .light, .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold, .heavy, .black: .bold
        default: .regular
        }
    }

    /// A Lato font for one of the system text styles, at that style's default size,
    /// scaling with Dynamic Type from there.
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        guard isAvailable else { return .system(style).weight(weight) }
        return .custom(face(for: weight).rawValue, size: size(of: style), relativeTo: style)
    }

    /// A Lato font at a fixed point size that still scales, for the handful of places
    /// a glyph is sized to its container rather than to a text style.
    static func font(fixedSize: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        guard isAvailable else { return .system(size: fixedSize, weight: weight) }
        return .custom(face(for: weight).rawValue, size: fixedSize, relativeTo: style)
    }

    /// A Lato font at a point size that does **not** scale — the replacement for a bare
    /// `.system(size:weight:)`.
    ///
    /// `Font.custom(_:fixedSize:)` rather than `Font.custom(_:size:relativeTo:)`, and the
    /// distinction is the whole reason this exists beside ``font(fixedSize:relativeTo:)``.
    /// The one caller is a monogram sized as a fraction of the tile it is centred in
    /// (``AvatarView``), and that tile is *already* a `@ScaledMetric`: scaling the glyph a
    /// second time would compound the two, and a monogram would grow out of its own square
    /// at the accessibility sizes. `.system(size:)` has exactly this behaviour, so this is
    /// the like-for-like swap and not a quiet change of one.
    static func font(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard isAvailable else { return .system(size: fixedSize, weight: weight) }
        return .custom(face(for: weight).rawValue, fixedSize: fixedSize)
    }

    /// The `UIFont` behind the same choice, for the surfaces UIKit still draws: the
    /// navigation bar's title, the tab bar's item labels, and the composer's text
    /// view. Scaled through `UIFontMetrics` because a `UIFont` does not scale itself.
    static func uiFont(_ style: UIFont.TextStyle, weight: Font.Weight = .regular) -> UIFont {
        let size = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        guard isAvailable, let lato = UIFont(name: face(for: weight).rawValue, size: size) else {
            return UIFontMetrics(forTextStyle: style).scaledFont(
                for: .systemFont(ofSize: size, weight: weight.uiKit)
            )
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: lato)
    }

    /// A text style's point size at the default content size — the base
    /// `relativeTo:` scales away from.
    ///
    /// A literal table rather than a `UIFontDescriptor` lookup per call: the lookup
    /// allocates a trait collection and a descriptor on a path that runs once per
    /// `Text` in a scrolling message list. `TypographyTests` asserts every entry
    /// against `UIFontDescriptor.preferredFontDescriptor(withTextStyle:compatibleWith:)`,
    /// so the table cannot drift from the system's without going red.
    ///
    /// `.body`'s 17 is also the answer for anything not listed — the accessibility-only
    /// styles a later SDK adds — so a style this app never sets still resolves to a
    /// readable size rather than to nothing.
    static func size(of style: Font.TextStyle) -> CGFloat {
        defaultSizes[style] ?? 17
    }

    /// The table itself. Built once, at first use, and read without allocating.
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
}

extension HiveTypography {
    /// Puts Lato on the chrome UIKit still draws for us.
    ///
    /// Two surfaces need it and neither can be reached from SwiftUI. A `Tab`'s label
    /// is handed to `UITabBar`, which renders the title itself and ignores a `.font`
    /// on the SwiftUI label; the navigation bar does the same with its title. Both
    /// are configured through their appearance proxies, once, before the first
    /// window is built — set after a bar exists and the bar keeps the old font until
    /// something forces it to rebuild.
    ///
    /// Everything else in the app is SwiftUI text and takes the environment font or
    /// an explicit `.hive(_:)`.
    ///
    /// `@MainActor` because every appearance proxy it touches is: `App.init()`, its one
    /// caller, is already on the main actor, so this costs nothing and is the difference
    /// between the isolation being checked and being assumed.
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
    /// The `UIFont.Weight` this corresponds to, for the UIKit fallback path.
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

extension Font {
    /// The app's typeface at one of the system text styles.
    ///
    /// The replacement for `.body`, `.caption.weight(.semibold)` and the rest at
    /// every call site: `.hive(.caption, weight: .semibold)`. Semantic styles rather
    /// than point sizes, so Dynamic Type still governs.
    static func hive(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        HiveTypography.font(style, weight: weight)
    }

    /// The app's typeface at a fixed size that still scales with `style`.
    static func hive(fixedSize: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        HiveTypography.font(fixedSize: fixedSize, relativeTo: style, weight: weight)
    }

    /// The app's typeface at a size that does not scale. See
    /// ``HiveTypography/font(fixedSize:weight:)`` for when that is the correct choice —
    /// it is rare, and it is always a glyph sized to a container that scales already.
    static func hive(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        HiveTypography.font(fixedSize: fixedSize, weight: weight)
    }

    /// Monospaced text — a code block, an inline code span, an `npub`, a SAS code — stays
    /// on the system's monospaced face.
    ///
    /// Lato has no monospaced cut, and asking for one gets Lato back rather than an error:
    /// `Font.monospaced()` promises "a fixed-width font *from the same family*", and Lato's
    /// family has none, so the request is dropped exactly the way ``HiveTypography`` records
    /// the weight trait being dropped. Every place this is called is a place where column
    /// alignment or character-by-character comparison is the entire point — a key someone is
    /// checking against another screen, a code block, the six digits of a pairing check — so
    /// this names the system face explicitly rather than leaving it to a modifier that would
    /// silently do nothing.
    static func hiveMono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    /// Monospaced at a size that does not scale — the SAS code, which is sized to be read
    /// across a desk rather than to a text style.
    static func hiveMono(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: fixedSize, weight: weight, design: .monospaced)
    }

    /// The font an **SF Symbol** is measured against, which is San Francisco and stays San
    /// Francisco.
    ///
    /// A symbol is not text in the app's typeface — it is a glyph out of the system's own
    /// symbol font, drawn at the point size and weight of whatever font it inherits. Handing
    /// it Lato costs the weight and gains nothing: the descriptor has no weight axis (see
    /// ``HiveTypography``), so `.hive(.body, weight: .semibold)` on a chevron draws the
    /// regular-weight chevron, and every `+`, `#`, and `↓` in the app that was deliberately
    /// heavier than its neighbours would quietly flatten.
    ///
    /// So symbols keep the system font, at the same text style as the text beside them, and
    /// say so at the call site. The size is unchanged either way — Lato's `.body` is 17pt and
    /// so is San Francisco's — which is why this is a naming decision rather than a metric
    /// one, and why it is worth having a name at all: a bare `.system(...)` here would read
    /// as a site the Lato sweep missed.
    static func hiveSymbol(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, weight: weight)
    }

    /// An SF Symbol at a size that does not scale — a hero glyph sized to a layout rather
    /// than to the text beside it. See ``hiveSymbol(_:weight:)``.
    static func hiveSymbol(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: fixedSize, weight: weight)
    }
}
