import SwiftUI
import WebKit

/// The document-only renderer: one web text surface, so a selection can cross every block.
///
/// Messages stay on ``RichTextView``. A file gets HTML because native `Text` scopes selection
/// to one view, while the browser gives headings, lists, tables and code their native document
/// layout without a second TextKit implementation.
struct MarkdownDocumentWebView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.hiveTheme) private var theme
    @Environment(\.openURL) private var openURL

    let message: RichMessage
    let baseURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(baseURL: baseURL, openURL: openURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.baseURL = baseURL
        context.coordinator.openURL = openURL

        let html = documentHTML(for: webView)
        guard context.coordinator.lastHTML != html
                || context.coordinator.lastDynamicTypeSize != dynamicTypeSize
        else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastDynamicTypeSize = dynamicTypeSize
        webView.backgroundColor = UIColor(theme.background)
        webView.scrollView.backgroundColor = UIColor(theme.background)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private func documentHTML(for webView: WKWebView) -> String {
        let traits = webView.traitCollection
        let background = css(UIColor(theme.background), traits: traits)
        let foreground = css(.label, traits: traits)
        let secondary = css(.secondaryLabel, traits: traits)
        let border = css(.separator, traits: traits)
        let codeGround = css(.secondarySystemGroupedBackground, traits: traits)
        let accent = css(theme.uiAccent, traits: traits)
        return MarkdownDocumentHTML.document(
            for: message,
            palette: MarkdownDocumentHTML.Palette(
                colorScheme: colorScheme == .dark ? "dark" : "light",
                background: background,
                foreground: foreground,
                secondary: secondary,
                border: border,
                codeGround: codeGround,
                accent: accent
            )
        )
    }

    private func css(_ color: UIColor, traits: UITraitCollection) -> String {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "rgb(0 0 0)"
        }
        return String(
            format: "rgb(%d %d %d / %.3f)",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            alpha
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var baseURL: URL
        var openURL: OpenURLAction
        var lastHTML: String?
        var lastDynamicTypeSize: DynamicTypeSize?

        init(baseURL: URL, openURL: OpenURLAction) {
            self.baseURL = baseURL
            self.openURL = openURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }

            if isInPageAnchor(url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                openURL(url)
            }
        }

        private func isInPageAnchor(_ url: URL) -> Bool {
            guard url.fragment != nil else { return false }
            return removingFragment(from: url) == removingFragment(from: baseURL)
        }

        private func removingFragment(from url: URL) -> URL? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                return nil
            }
            components.fragment = nil
            return components.url
        }
    }
}
