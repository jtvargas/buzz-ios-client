import BuzzKit
import SwiftUI
import UIKit

/// Share, as a control on the picture rather than a row two taps away.
///
/// # What is shared, and why it is not the URL
///
/// The file ``MessageMediaExport`` fetches — the *original bytes*, written to disk under the
/// name and type they were posted with. Not the picture's URL, and not the bitmap on screen:
///
/// - The **URL** is the cheap item and the wrong one. This deployment's media host is
///   tailnet-only, so a link handed to anybody outside resolves to nothing for them.
/// - The **bitmap on screen** has been downsampled by ImageIO to the pixel size of the box it
///   fills and re-encoded on the way. AirDropping it would hand someone a reduction of the
///   thing they asked for.
///
/// A file also arrives as itself: Mail attaches a `.jpeg`, Photos imports the format it was
/// posted in. An in-memory `UIImage` arrives re-encoded and anonymous.
///
/// # Why it waits rather than fetching on the tap
///
/// The original is fetched when the page appears, so the sheet opens on the picture instead of
/// on a spinner. Until it lands the control is drawn and disabled — drawn, not omitted,
/// because a button that appears next to the close button a second after the viewer opens
/// moves the one control that was already there, under a thumb that is reaching for it.
struct MessageMediaShareButton: View {
    let media: MessageMedia
    /// What is already on screen, used for the share sheet's thumbnail only — never as the
    /// thing shared. See above.
    var preview: UIImage?
    /// The session the original is fetched over. Injectable so a test can answer without a
    /// relay; defaults to the one session every export shares.
    var session: URLSession = MessageMediaExport.session

    /// The session's grant for reading relay media, which a gated relay refuses the fetch
    /// without. Optional because the viewer is also built by previews and tests, which mount
    /// no environment — there it is `nil` and the fetch goes out unsigned, as it always did.
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    /// The fetched original, on disk. Its presence is the whole arming condition.
    @State private var file: URL?

    var body: some View {
        content
            // Keyed by the picture, so paging the gallery fetches the one now on screen and
            // abandons the one that is not.
            .task(id: media.url) {
                file = try? await MessageMediaExport.fetch(
                    media, session: session, authorization: environment?.mediaReadAuthorizer
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if let file {
            ShareLink(item: file, preview: sharePreview) {
                glyph
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .accessibilityLabel("Share picture")
            .accessibilityIdentifier(Self.identifier)
        } else {
            // The same control, inert. See the note above on why it is drawn and not omitted.
            Button {} label: { glyph }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .disabled(true)
                .accessibilityLabel("Share picture")
                .accessibilityIdentifier(Self.identifier)
        }
    }

    /// Sized exactly as ``MessageMediaViewer/closeButton``'s glyph is, and for its reason: the
    /// glass style adds a measured ~14pt around whatever label it is given, so 30 is what
    /// produces a 44pt control. Two circles side by side have to agree about that or the row
    /// reads as a mistake.
    private var glyph: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.hiveSymbol(.body, weight: .semibold))
            .frame(width: 30, height: 30)
    }

    /// What the share sheet draws while the reader chooses where the picture is going. Always
    /// carries an image — a symbol where nothing has decoded yet — because a preview without
    /// one collapses the sheet's header to a bare filename.
    private var sharePreview: SharePreview<Image, Never> {
        let title = media.alt ?? "Picture"
        let image = preview.map { Image(uiImage: $0) } ?? Image(systemName: "photo")
        return SharePreview(title, image: image)
    }

    static let identifier = "mediaViewerShare"
}
