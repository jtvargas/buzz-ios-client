import SwiftUI
import UIKit

/// The app's accent: the honey amber in `App/Resources/Assets.xcassets/AccentColor`.
///
/// The asset is read *by name* rather than through `Color.accentColor`, and the difference
/// is the whole reason this exists. Setting the catalogue's global accent — which this
/// project does, in `project.yml`, and which writes `NSAccentColorName` into the built
/// `Info.plist` — turns out not to reach either framework on iOS: measured on the simulator,
/// `Color.accentColor` resolves to sRGB (0, 0.569, 1) and a fresh `UIView`'s `tintColor` to
/// the same, which is the system blue, while the asset itself resolves to the amber it
/// holds. Everything the app had drawn "in the accent" was therefore drawing in blue.
///
/// So the accent is applied by hand, in three places, and each of them is one line:
///
/// - `.tint(.hiveAccent)` on the app's window group, for SwiftUI's own controls;
/// - ``SwiftUI/View/hiveWindowTint()`` on the same, for the UIKit chrome underneath —
///   alerts, menus, selection handles, the caret in a `UITextView`;
/// - `.hiveAccent` / ``uiColor`` at any call site that draws the accent itself.
/// The theme in force, held as something SwiftUI can **observe**.
///
/// # Why this exists at all, when a `static var` would hold a colour just as well
///
/// It was a `static var` first, and that shipped the defect this type is the fix for. SwiftUI
/// re-draws a view when a value it *read while building* changes, and it can only know about a
/// read it can see: `@Observable`, `@Environment`, `@State`. A bare global is none of those. So
/// every view that drew `Color.hiveAccent` and had no other reason to re-render kept the
/// **outgoing** accent after a theme change — the shortcut cards held their amber edge and wash
/// while the tab bar beside them went green, and which views updated depended on nothing but
/// whether something else happened to invalidate them first. That reads as random, and the
/// owner reported it as random.
///
/// Reading through `@Observable` puts all thirty-odd accent call sites back on the dependency
/// graph **without one of them changing**, which is why the fix is here and not spread across
/// them. Each still says `.hiveAccent`; the read now registers.
///
/// # Why a box rather than the environment
///
/// The accent is read from places that have no environment to read from — `static` colours on
/// style types (``PressFeedbackButtonStyle/fillColor``, ``RichTextStyle/tint``) and UIKit's
/// window tint. Those cannot take an `@Environment` and would each need a parameter threaded to
/// them from every caller. The environment carries the theme as well (`\.hiveTheme`), for the
/// ground; the two agree because both are written from the same preference.
///
/// # Isolation
///
/// `@unchecked Sendable` with the same discipline the `nonisolated(unsafe)` global it replaces
/// documented: written on the main actor, read on the main actor. Marking it `@MainActor`
/// instead would push that annotation onto `Color.hiveAccent` and from there onto every call
/// site, for a value that has never been touched off the main thread.
@Observable
final class HiveThemeBox: @unchecked Sendable {
    /// The one box.
    static let shared = HiveThemeBox()

    /// Written by ``AppSettings/themeID`` and nothing else — one writer, so this stays a mirror
    /// of the stored preference rather than a second source of truth that can drift from it.
    ///
    /// Deliberately *not* written from ``SwiftUI/View/hiveTheme(_:)``, which is where it used to
    /// happen: that is a view-building function, and mutating observed state while SwiftUI is
    /// building a view is the "Modifying state during view update" hazard. The preference's
    /// `didSet` fires from a button action instead, which is a moment SwiftUI is not mid-update.
    var theme: HiveTheme = .hive

    private init() {}
}

enum HiveAccent {
    /// The catalogue name. One string, so a typo is one test away rather than eight.
    static let assetName = "AccentColor"

    /// The accent the app is currently drawing — the chosen ``HiveTheme``'s, or the amber asset
    /// until a theme says otherwise.
    static var current: Color { HiveThemeBox.shared.theme.accent }

    /// The accent as UIKit sees it, for the window tint and anything else drawing through
    /// `UIColor`.
    ///
    /// Built by the theme rather than bridged with `UIColor(current)`. `UIColor(someSwiftUIColor)`
    /// is not the identity it looks like: bridging the amber *asset* through it produces a colour
    /// that no longer answers `resolvedColor(with:)` per appearance, and the amber has a light
    /// entry and a dark one. Doing that cost the window tint its colour — the caret, the
    /// selection handles, menus and alerts — and ``AccentTests`` is what said so. See
    /// ``HiveTheme/uiAccent``.
    static var uiColor: UIColor { HiveThemeBox.shared.theme.uiAccent }
}

extension ShapeStyle where Self == Color {
    /// The app's accent — the chosen ``HiveTheme``'s, or the honey amber in the asset catalogue
    /// for anyone who has never opened the picker.
    ///
    /// Prefer this to `Color.accentColor` for anything that is meant to be *the app's
    /// colour*. `.accentColor` is inherited and overridable — correct for a control that
    /// should follow the tint it is placed in, wrong for a brand mark that should not
    /// change because an enclosing view tinted itself.
    static var hiveAccent: Color { HiveAccent.current }

    /// The ground the chosen theme draws every screen on.
    ///
    /// For the handful of marks whose colour *is* the ground rather than merely sitting on it —
    /// the ring that punches an avatar out of the row behind it, the rail that has to end where
    /// the screen does. Those said ``hiveNight`` before there was more than one ground, and a
    /// fixed near-black ring on a Nord screen is a dark hole rather than a separator.
    ///
    /// Not for a *surface*: a screen says ``SwiftUI/View/hiveScreenGround()``, which crossfades.
    static var hiveGround: Color { HiveThemeBox.shared.theme.background }
}

extension View {
    /// Puts a theme into force: into the environment for the ground, and onto the window UIKit
    /// tints.
    ///
    /// Said once, on the app's window content. It does **not** write ``HiveThemeBox`` — see the
    /// note on ``HiveThemeBox/theme`` for why a view-building function is the wrong place to
    /// mutate observed state from.
    func hiveTheme(_ theme: HiveTheme) -> some View {
        environment(\.hiveTheme, theme)
            .tint(theme.accent)
            .background(WindowTint(color: theme.uiAccent).allowsHitTesting(false))
    }
}

extension View {
    /// Puts the accent on the window this view lands in, for everything UIKit draws.
    ///
    /// `tintColor` is not an appearance-proxy property — `UIWindow.appearance().tintColor`
    /// compiles, runs, and does nothing — so the window has to be reached at runtime and
    /// told. A zero-size backing view is the whole mechanism: it is added to the hierarchy,
    /// finds its window, and sets the tint every `UIView` under it inherits.
    func hiveWindowTint() -> some View {
        background(WindowTint(color: HiveAccent.uiColor).allowsHitTesting(false))
    }
}

/// The view behind ``SwiftUI/View/hiveWindowTint()``. Not private: its `UIView` is what the
/// accent test drives, because "the app's window is amber" is not a claim SwiftUI can be
/// asked about directly.
struct WindowTint: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> TintingView {
        TintingView(color: color)
    }

    func updateUIView(_ view: TintingView, context: Context) {
        view.color = color
        view.applyTint()
    }

    /// Applies the tint whenever it lands in a window — which is the only moment it can be
    /// applied, since a view built by `makeUIView` has no window yet.
    final class TintingView: UIView {
        var color: UIColor

        init(color: UIColor) {
            self.color = color
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyTint()
        }

        func applyTint() {
            window?.tintColor = color
        }
    }
}
