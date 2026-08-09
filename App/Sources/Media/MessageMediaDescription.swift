import BuzzKit
import Foundation

/// What an attachment is *called* — on screen when there is nothing to draw, and to
/// VoiceOver always.
///
/// Pure and separate from the view for the same reason ``MessageAccessibility`` is: the
/// phrasing is the only thing a reader who cannot see the picture gets, so it is worth
/// asserting on directly rather than inferring from a screenshot.
///
/// # `alt` is the label, and the fallback is not the URL
///
/// NIP-92's `alt` exists for exactly this and is used verbatim wherever the author
/// supplied one. Where they did not, the fallback is the *kind* — "Image" — and never the
/// URL: relay media is stored under a 64-character content hash, so reading the address
/// aloud is a minute of hexadecimal that tells nobody anything. The file name is shown on
/// the video placeholder, where naming the thing that will not play is the whole point of
/// the placeholder, and it is middle-truncated there for the same reason keys are.
enum MessageMediaDescription {
    /// Where a load has got to. Video has no state of its own: nothing is fetched for it
    /// in this version.
    enum LoadState {
        case loading
        case loaded
        case failed
    }

    /// The accessibility label — and, for the failure notice, the text drawn in the box.
    static func label(for media: MessageMedia, state: LoadState) -> String {
        let alt = trimmed(media.alt)
        switch media.kind {
        case .video:
            return alt.map { "\($0), video attachment" } ?? "Video attachment"
        case .file:
            return media.filename ?? "File attachment"
        case .image:
            switch state {
            case .loading:
                return alt.map { "\($0), loading" } ?? "Image, loading"
            case .loaded:
                return alt ?? "Image"
            case .failed:
                return alt.map { "\($0), image unavailable" } ?? "Image unavailable"
            }
        }
    }

    /// The status read after the label, or `nil` when there is nothing to add.
    ///
    /// A video says so here rather than in the label, so an author's `alt` is still the
    /// first thing heard and the caveat arrives after it.
    static func value(for media: MessageMedia) -> String? {
        media.kind == .video ? "Not playable in this version" : nil
    }

    /// What activating the attachment does, or `nil` when it does nothing.
    static func hint(for media: MessageMedia, state: LoadState) -> String? {
        guard media.kind == .image else { return nil }
        switch state {
        case .loaded: return "Shows the picture full screen"
        case .failed: return "Tries the download again"
        case .loading: return nil
        }
    }

    /// The short line drawn *inside* a placeholder box, under its glyph.
    ///
    /// Deliberately shorter than the accessibility label: the box is at most 320 points
    /// wide and a sentence in it wraps to four lines of caption, which reads as an error
    /// dialog rather than as a picture that did not arrive.
    static func placeholderText(for media: MessageMedia, state: LoadState) -> String {
        switch media.kind {
        case .video:
            return trimmed(media.alt) ?? fileName(for: media.url) ?? "Video"
        case .file:
            return media.filename ?? fileName(for: media.url) ?? "File"
        case .image:
            guard state == .failed else { return "" }
            return trimmed(media.alt) ?? "Image unavailable"
        }
    }

    /// The last path component of `url`, middle-truncated, or `nil` when the URL carries
    /// no name worth showing.
    ///
    /// Middle rather than tail truncation, matching how the app draws keys and channel
    /// ids: the *extension* is the informative half of a media file name, and truncating
    /// from the end is precisely the half that would be lost.
    static func fileName(for url: String, limit: Int = 22) -> String? {
        guard let name = URL(string: url)?.lastPathComponent, !name.isEmpty, name != "/" else { return nil }
        guard name.count > limit else { return name }
        // Split the budget with the ellipsis: enough leading characters to distinguish two
        // uploads, enough trailing ones to keep the extension.
        let trailing = max(4, limit / 3)
        let leading = max(1, limit - trailing - 1)
        return name.prefix(leading) + "…" + name.suffix(trailing)
    }

    /// `text` with surrounding whitespace removed, or `nil` when nothing is left. An
    /// `alt` of `" "` is a tag that carried the key and no content, and treating it as a
    /// label would leave VoiceOver announcing an empty string.
    private static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}
