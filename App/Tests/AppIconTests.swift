import Foundation
import Testing

@Suite("App icon")
struct AppIconTests {
    /// `App/Resources/hive-buzz-app.icon` — the Icon Composer document — without its
    /// extension, which is the form `ASSETCATALOG_COMPILER_APPICON_NAME` takes.
    private static let documentName = "hive-buzz-app"

    @Test("the built app's icon is the Icon Composer document")
    func primaryIconIsTheIconComposerDocument() throws {
        // Two things in `project.yml` have to agree for this icon to reach a home
        // screen, and both were once true only inside a locally opened
        // `Hive.xcodeproj` — a generated file that every `xcodegen generate`
        // overwrites, including the one CI runs. So Xcode showed the right icon while
        // every build, on the phone included, shipped a different one.
        //
        // `actool` writes this key from its `--app-icon` argument, which makes it the
        // compiled evidence rather than a restatement of the setting: it can only read
        // `hive-buzz-app` if the build setting named the document *and* the document
        // reached `actool` as an input catalog.
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == Self.documentName)
    }

    @Test("the icon document is compiled rather than copied in as raw artwork")
    func iconDocumentIsCompiledRatherThanCopied() {
        // XcodeGen 2.44 does not know the `.icon` extension, so a bare `App/Resources`
        // source entry walks *into* the document and adds `icon.json` and each layer
        // image to the resources phase as ordinary files. That build still succeeds: it
        // copies 330 KB of raw art into the bundle and compiles no icon at all, which
        // is the failure this pair exists to name. `project.yml` declares the document
        // with `type: file` so the wrapper stays whole and `actool` receives it.
        //
        // `icon.json` is Icon Composer's own manifest filename, so it is what surfaces
        // whatever the layers are called.
        #expect(
            Bundle.main.url(forResource: "icon", withExtension: "json") == nil,
            "icon.json is in the bundle, so the icon document was walked into instead of compiled"
        )
        let wrapper = Bundle.main.bundleURL.appendingPathComponent("\(Self.documentName).icon")
        #expect(
            !FileManager.default.fileExists(atPath: wrapper.path),
            "\(wrapper.lastPathComponent) was copied into the bundle instead of compiled"
        )
    }
}
