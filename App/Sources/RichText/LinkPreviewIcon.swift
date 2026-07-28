import SwiftUI

/// The fixed-size SF Symbol at the leading edge of a link card.
///
/// Every link kind has a stable glyph, so cards have no image request or late-arriving
/// content. The 20-point square keeps the card's measurement independent of the symbol.
enum LinkPreviewIcon {
    /// The side of the icon's square, in points. Fixed, so the card's height does not
    /// depend on the glyph resolved for a link kind.
    static let size: CGFloat = 20

    /// The glyph that identifies the linked resource.
    ///
    /// SF Symbols, so they inherit the card's colour and Dynamic Type; named per kind
    /// rather than one generic mark, because on the cards this app draws most often —
    /// a pull request from CI, a repository — the shape is the useful half of the card
    /// before any pixel arrives from the network.
    static func symbol(for kind: LinkPreview.Kind) -> String {
        switch kind {
        case .githubPullRequest: "arrow.triangle.pull"
        case .githubIssue, .linearIssue: "smallcircle.filled.circle"
        case .githubRepository: "book.closed"
        case .googleDriveFile: "doc"
        case .googleDriveFolder: "folder"
        case .googleDocument: "doc.text"
        case .googleSpreadsheet: "tablecells"
        case .googlePresentation: "rectangle.on.rectangle"
        case .web: "network"
        }
    }
}

/// The icon slot for a link card.
struct LinkPreviewIconView: View {
    let preview: LinkPreview

    var body: some View {
        Image(systemName: LinkPreviewIcon.symbol(for: preview.kind))
            .font(.hiveSymbol(.footnote))
            .foregroundStyle(.secondary)
            .frame(width: LinkPreviewIcon.size, height: LinkPreviewIcon.size)
            .accessibilityHidden(true)
    }
}
