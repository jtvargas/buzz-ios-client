import SwiftUI
import UIKit

/// A named ground-and-accent pair the reader can choose in Settings.
///
/// # Where these come from
///
/// The backgrounds are taken verbatim from the mobile Buzz client's theme catalogue
/// (`mobile/lib/shared/theme/theme_catalog.dart`), which carries 60 Shiki syntax themes as
/// `bg`/`fg`/`comment` triples and calls one dark when its background luminance is under 0.5.
/// Forty-three of them are dark; these are the ones with the most recognisable names and the
/// most distinct backgrounds, so the picker reads as a set of real themes rather than a row of
/// near-identical greys.
///
/// # Why the accents are not from that catalogue
///
/// Upstream keeps the accent on a *separate* axis: nine fixed accents in `accent_colors.dart`
/// (Blue, Cyan, … Black), chosen independently of the theme, defaulting to Black — which in a
/// dark scheme resolves to the foreground, i.e. off-white. Faithful, and useless for a proof of
/// concept about accent colour, since every theme would look the same.
///
/// So each theme here carries its own palette's signature colour instead — Catppuccin's mauve,
/// Gruvbox's orange, Nord's frost blue. Those are the canonical accents those palettes are known
/// by, not values extracted from upstream's file. It is the one place this deliberately diverges,
/// and it is what makes choosing a theme visibly change two things rather than one.
///
/// # The two Slack entries
///
/// Upstream's catalogue does carry a `slack-dark`, and ``all`` takes its `#222222` background
/// verbatim like every other one. But `#222222` is a plain grey — next to Gruvbox's `#282828` it
/// is not recognisably anything, least of all Slack. So there is a second entry, **Slack
/// Aubergine**, on the sidebar purple the product is actually known by. Neither is a compromise
/// on the other: the first is what the catalogue says, the second is what Slack looks like.
///
/// **Slack Aubergine**'s accent is Slack's own brand blue rather than upstream's `added` field,
/// which records `#ECB22E` for `slack-dark` — within a few degrees of Hive's own `#FFBA38`.
///
/// **Slack Dark** carried that same brand blue until the owner asked for Hive's accent on it
/// (2026-08-06), so it now takes `nil` like ``hive`` and draws the asset catalogue's amber. The
/// swatch cost the brand blue was avoiding is real and was accepted: Slack Dark and Hive differ
/// in the picker only by their ground, `#222222` against `hiveNight`. Taking `nil` rather than
/// hardcoding `#FFBA38` is deliberate — it puts this theme on the same light/dark-resolving
/// asset path ``AccentTests`` already guards, which a literal would silently leave.
struct HiveTheme: Identifiable, Equatable, Sendable {
    /// The upstream catalogue's own name, and the persisted value. Stable across releases:
    /// changing one silently resets the reader's choice to the default.
    let id: String
    /// What Settings calls it.
    let name: String
    /// The screen ground — upstream's `bg`, unmodified.
    let background: Color
    /// The palette's signature colour as the catalogue writes it, `0xRRGGBB` — or `nil` for
    /// ``hive``, whose accent is the asset catalogue's amber rather than one number.
    let accentHex: UInt32?

    /// The colour the app draws "its own" marks in.
    var accent: Color {
        accentHex.map(Color.hex) ?? Color(HiveAccent.assetName, bundle: .main)
    }

    /// The same accent for UIKit — the window tint, and so the caret, the selection handles,
    /// menus and alerts.
    ///
    /// Built here rather than bridged with `UIColor(accent)`, because ``hive``'s accent is an
    /// asset with a *light entry and a dark one* and bridging it through SwiftUI produces a
    /// colour that stops resolving per appearance. That is a silent failure — the tint is still
    /// a colour, just the wrong one — and ``AccentTests`` is the only thing that says so.
    var uiAccent: UIColor {
        guard let accentHex else { return UIColor(named: HiveAccent.assetName) ?? .tintColor }
        return .hex(accentHex)
    }

    static func == (lhs: HiveTheme, rhs: HiveTheme) -> Bool { lhs.id == rhs.id }
}

extension HiveTheme {
    /// Hive's own colours, unchanged — `hiveNight` and the honey amber in the asset catalogue.
    /// First in the list and the default, so an install that has never opened Settings looks
    /// exactly as it did before this existed.
    static let hive = HiveTheme(
        id: "hive",
        name: "Hive",
        background: Color.hiveNight,
        accentHex: nil
    )

    /// The fourteen alternatives, ordered by the WCAG relative luminance of their background so
    /// the picker reads as a gradient rather than an arbitrary list. ``hive`` is pinned first
    /// regardless, because it is the default and the one somebody scrolls back to.
    static let all: [HiveTheme] = [
        .hive,
        HiveTheme(id: "vitesse-black", name: "Vitesse Black", background: .hex(0x000000), accentHex: 0x4D9375),
        HiveTheme(id: "github-dark-default", name: "GitHub Dark", background: .hex(0x0D1117), accentHex: 0x58A6FF),
        HiveTheme(id: "night-owl", name: "Night Owl", background: .hex(0x011627), accentHex: 0x82AAFF),
        HiveTheme(id: "rose-pine", name: "Rosé Pine", background: .hex(0x191724), accentHex: 0xC4A7E7),
        HiveTheme(id: "tokyo-night", name: "Tokyo Night", background: .hex(0x1A1B26), accentHex: 0x7AA2F7),
        HiveTheme(id: "catppuccin-mocha", name: "Catppuccin Mocha", background: .hex(0x1E1E2E), accentHex: 0xCBA6F7),
        HiveTheme(id: "slack-dark", name: "Slack Dark", background: .hex(0x222222), accentHex: nil),
        HiveTheme(id: "slack-aubergine", name: "Slack Aubergine", background: .hex(0x3F0E40), accentHex: 0x36C5F0),
        HiveTheme(id: "solarized-dark", name: "Solarized Dark", background: .hex(0x002B36), accentHex: 0x2AA198),
        HiveTheme(id: "monokai", name: "Monokai", background: .hex(0x272822), accentHex: 0xA6E22E),
        HiveTheme(id: "gruvbox-dark-medium", name: "Gruvbox Dark", background: .hex(0x282828), accentHex: 0xFE8019),
        HiveTheme(id: "dracula", name: "Dracula", background: .hex(0x282A36), accentHex: 0xBD93F9),
        HiveTheme(id: "one-dark-pro", name: "One Dark Pro", background: .hex(0x282C34), accentHex: 0x61AFEF),
        HiveTheme(id: "nord", name: "Nord", background: .hex(0x2E3440), accentHex: 0x88C0D0),
    ]

    /// The theme a stored id names, or ``hive`` when it names nothing — an id written by a later
    /// version, or by a hand-edited defaults file, must not leave the app with no ground at all.
    static func named(_ id: String?) -> HiveTheme {
        guard let id, let match = all.first(where: { $0.id == id }) else { return .hive }
        return match
    }
}

extension UIColor {
    /// The same conversion as ``SwiftUI/Color/hex(_:)``, for the UIKit side of the accent.
    ///
    /// A fixed colour rather than a dynamic one, and correctly so: these come from a catalogue
    /// of *dark* themes, which have one appearance and not two.
    static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// A theme's colour as the catalogue writes it: `0xRRGGBB`, fully opaque.
    ///
    /// `Color(red:green:blue:)` takes sRGB components, which is the space the upstream catalogue
    /// records and the space `Color(0x…)` would be read in anyway — so the conversion is exact
    /// rather than passing through a display-P3 widening.
    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
