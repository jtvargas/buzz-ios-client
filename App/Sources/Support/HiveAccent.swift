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

    /// The accent as UIKit sees it. Falls back to the system tint rather than trapping:
    /// a missing asset is a wrong colour, not a reason for the app not to open.
    static var uiColor: UIColor {
        UIColor(named: assetName) ?? .tintColor
    }
}

extension ShapeStyle where Self == Color {
    /// The app's accent, read from the asset catalogue.
    ///
    /// Prefer this to `Color.accentColor` for anything that is meant to be *the app's
    /// colour*. `.accentColor` is inherited and overridable — correct for a control that
    /// should follow the tint it is placed in, wrong for a brand mark that should not
    /// change because an enclosing view tinted itself.
    static var hiveAccent: Color { Color(HiveAccent.assetName, bundle: .main) }
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
