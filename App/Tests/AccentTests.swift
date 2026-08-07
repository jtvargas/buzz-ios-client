import SwiftUI
import Testing
import UIKit

@testable import Hive

/// The app's accent, and the two places it has to arrive for the app to be amber rather
/// than blue: SwiftUI, which reads a colour by name, and UIKit, which reads a window's tint.
///
/// Written as a test because the failure it guards against is silent and total. Nothing
/// warns when the catalogue's accent is not applied — every button, link, caret and mention
/// token simply draws in the system blue, which is a colour, so nothing looks broken.
///
/// # Why these name ``HiveTheme/hive`` instead of reading the live accent
///
/// They are about the *asset* and the *wiring*, not about which theme is chosen. Reading
/// ``HiveAccent/uiColor`` here made them assert "the app is amber" against a global the host
/// app writes at launch from `UserDefaults.standard` — so a machine whose simulator had ever
/// had a theme picked turned three of these red with that theme's own accent, which is not a
/// defect in anything they test. Naming the default theme asks the question they actually
/// mean. The live global has tests of its own, in ``AppSettingsTests``.
@Suite("Accent", .timeLimit(.minutes(1)))
struct AccentTests {
    @Test("the accent asset exists under the name every call site uses")
    func assetIsPresent() {
        // `Color("AccentColor")` renders as a bright pink placeholder rather than failing
        // when the name is wrong, and `UIColor(named:)` quietly returns nil. One assertion
        // here is the whole of the typo protection for the name.
        #expect(UIColor(named: HiveAccent.assetName, in: .main, compatibleWith: nil) != nil)
    }

    @Test("the accent is the catalogue's amber in both appearances")
    @MainActor
    func resolvesToAmber() {
        // The two entries of `AccentColor.colorset`, read back from the compiled catalogue.
        expect(HiveTheme.hive.uiAccent, in: .light, isNear: .light)
        expect(HiveTheme.hive.uiAccent, in: .dark, isNear: .dark)
    }

    @Test("the SwiftUI accent and the UIKit accent are the same colour")
    @MainActor
    func swiftUIMatchesUIKit() {
        // `.hiveAccent` is the same asset reached through SwiftUI. If these two ever drift,
        // a mention token in the composer's UIKit text view stops matching the same mention
        // rendered by SwiftUI one row above it.
        expect(UIColor(HiveTheme.hive.accent), in: .light, isNear: .light)
        expect(UIColor(HiveTheme.hive.accent), in: .dark, isNear: .dark)
    }

    @Test("landing in a window tints it, which is how UIKit gets the accent")
    @MainActor
    func windowCarriesTheTint() throws {
        // The UIKit half of the wiring, driven exactly as the app drives it: the backing
        // view of `.hiveWindowTint()` is added to a window, and everything under that
        // window — the composer's text view, its caret, its selection handles, a menu —
        // inherits the tint from it.
        //
        // The mechanism rather than the app's own window, because a window's tint before
        // this view has landed in it is a race, and because `UIWindow()` with no scene
        // traps on iOS 26. A scene is borrowed from the host app for the same reason.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // Nothing has tinted it yet. Asserted so the check below cannot pass by accident on
        // a system default that happens to match.
        #expect(window.tintColor == nil)

        window.addSubview(WindowTint.TintingView(color: HiveTheme.hive.uiAccent))
        expect(try #require(window.tintColor), in: .dark, isNear: .dark)
        expect(try #require(window.tintColor), in: .light, isNear: .light)
    }

    @Test("the default theme's accent still answers to both appearances")
    @MainActor
    func theDefaultThemeKeepsBothEntries() {
        // The property that broke when the accent started going through a theme: bridging the
        // amber with `UIColor(Color(…))` produces something that resolves to one colour whatever
        // appearance it is asked about, and the asset has a light entry and a dark one. Asserted
        // as "the two differ" rather than by value — the values are ``resolvesToAmber``'s job,
        // and what this one is about is that there are still two of them.
        let light = HiveTheme.hive.uiAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = HiveTheme.hive.uiAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(light != dark)
    }

    @Test("a picked theme reaches UIKit as its own colour")
    @MainActor
    func aPickedThemeReachesUIKit() {
        // The other half: a theme from the catalogue is one fixed colour, and it has to arrive
        // in UIKit as that colour — this is what the caret and the selection handles draw in
        // once somebody has chosen a theme. Nord's `#88C0D0`.
        let frost = HiveTheme.named("nord").uiAccent
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(frost.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(red - 0x88 / 255.0) < 0.01)
        #expect(abs(green - 0xC0 / 255.0) < 0.01)
        #expect(abs(blue - 0xD0 / 255.0) < 0.01)
    }

    /// Compares a colour resolved in one appearance against expected sRGB components.
    ///
    /// A tolerance, not equality: the catalogue stores 8-bit components for one entry and
    /// floats for the other, so a resolved channel is only ever *about* the number written
    /// in the asset — see the float-equality rule this project learned the hard way.
    @MainActor
    private func expect(
        _ color: UIColor,
        in style: UIUserInterfaceStyle,
        isNear expected: Amber,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), sourceLocation: sourceLocation)
        let difference = max(abs(red - expected.red), abs(green - expected.green), abs(blue - expected.blue))
        #expect(
            difference < 0.01,
            "\(resolved) is not \(expected)",
            sourceLocation: sourceLocation
        )
        #expect(abs(alpha - 1) < 0.01, sourceLocation: sourceLocation)
    }

    /// The two colours the catalogue holds, in the order a colour reports them.
    private struct Amber {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        /// `AccentColor.colorset`, the entry with no appearance on it.
        static let light = Amber(red: 0.961, green: 0.659, blue: 0.129)
        /// `AccentColor.colorset`, the `luminosity: dark` entry — 255, 186, 56.
        static let dark = Amber(red: 1.0, green: 0.729, blue: 0.220)
    }
}
