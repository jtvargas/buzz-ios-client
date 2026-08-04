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
enum HiveAccent {
    /// The catalogue name. One string, so a typo is one test away rather than eight.
    static let assetName = "AccentColor"

    /// The accent the app is currently drawing — the chosen ``HiveTheme``'s, or the amber asset
    /// until a theme says otherwise.
    ///
    /// A stored global rather than an environment value because the accent is read from places
    /// that have no environment to read: `static` colours on style types, and UIKit's window
    /// tint. Written only from ``SwiftUI/View/hiveTheme(_:)`` on the main actor as the reader
    /// changes theme, and read on the main actor everywhere else — hence `nonisolated(unsafe)`
    /// rather than an actor hop that every call site would have to become `async` to make.
    nonisolated(unsafe) static var current = Color(assetName, bundle: .main)

    /// The accent as UIKit sees it, for the window tint and anything else drawing through
    /// `UIColor`.
    static var uiColor: UIColor { UIColor(current) }
}

extension ShapeStyle where Self == Color {
    /// The app's accent, read from the asset catalogue.
    ///
    /// Prefer this to `Color.accentColor` for anything that is meant to be *the app's
    /// colour*. `.accentColor` is inherited and overridable — correct for a control that
    /// should follow the tint it is placed in, wrong for a brand mark that should not
    /// change because an enclosing view tinted itself.
    /// Now the *chosen theme's* accent rather than the asset directly — see
    /// ``HiveAccent/current``. Unchanged for anybody who has not picked a theme, since the
    /// default is that same asset.
    static var hiveAccent: Color { HiveAccent.current }
}

extension View {
    /// Puts a theme into force: into the environment for the ground, onto the accent every
    /// call site reads, and onto the window UIKit tints.
    ///
    /// Said once, on the app's window content. The accent is pushed into ``HiveAccent/current``
    /// *before* the environment is written so that the re-render the environment triggers
    /// already reads the new colour — the other order draws one frame in the outgoing accent.
    func hiveTheme(_ theme: HiveTheme) -> some View {
        HiveAccent.current = theme.accent
        return environment(\.hiveTheme, theme)
            .tint(theme.accent)
            .background(WindowTint(color: UIColor(theme.accent)).allowsHitTesting(false))
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
