import UIKit
import VisionKit

/// Live Text over the picture in the full-screen viewer: select it, copy it, look it up.
///
/// # Why VisionKit and not Vision
///
/// `VNRecognizeTextRequest` — Vision — returns strings and bounding boxes. It recognises text
/// and stops there: there is no selection, no grab handles, no menu, no highlight. Building
/// the interactive part on top of it means hand-drawing every one of those and getting them to
/// behave like the system's, over a picture that also pinches, pans and drags to dismiss.
///
/// `ImageAnalysisInteraction` — VisionKit — *is* the system's. It is the same object Photos,
/// Safari and Quick Look use, so a reader gets the selection they already know, in their own
/// language, with Copy, Look Up, Translate and Share where they expect them, and it keeps
/// working when Apple changes what Live Text does.
///
/// # What is analysed, and what is left out
///
/// `.text` only. `.machineReadableCode` would add QR codes and barcodes, and
/// `.visualLookUp` the "what plant is this" affordance — both are real features and neither is
/// what was asked for, and each is another thing competing for a touch on a surface whose
/// gestures are already crowded (see ``MessageMediaZoomView``). They are one option-set
/// element away if they are ever wanted.
///
/// # Why the analyser is shared and the analysis is not
///
/// `ImageAnalyzer` is documented as expensive to create and safe to reuse, so one serves the
/// process — the same reasoning ``MessageMediaExport`` applies to its `URLSession`. The
/// *analysis* is per picture and per decode: the viewer shows the inline bitmap first and
/// replaces it with the full-resolution one a moment later, and text found in the small one is
/// positioned for a picture that is no longer on screen.
enum MessageMediaLiveText {
    /// One analyser for the process. See the note above.
    static let analyzer = ImageAnalyzer()

    /// Whether this device can do it at all. `false` on a simulator without the Neural Engine
    /// bits, and on hardware Apple has not shipped Live Text to — in which case the picture is
    /// simply a picture, with no affordance drawn and nothing to explain.
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    /// The analysis for one decode, or `nil` if this device cannot do it, the picture holds no
    /// text, or the work was superseded.
    ///
    /// Failure is deliberately silent. There is no reader-facing action behind "this picture
    /// could not be analysed" — the alternative to selectable text is the picture they already
    /// have — so an alert would interrupt them to report the absence of a feature they may not
    /// have been reaching for.
    ///
    /// This type is deliberately *not* `@MainActor`, and the configuration is built here
    /// rather than shared. `ImageAnalyzer.Configuration` is not `Sendable`, so a value made on
    /// the main actor cannot be handed to the analyser's own isolation; one made here and
    /// passed straight on belongs to nobody else, which is what region-based isolation asks
    /// for. `ImageAnalyzer` itself is `@unchecked Sendable` and documented as reusable, so it
    /// has no business being pinned to the main actor either.
    static func analysis(of image: UIImage) async -> ImageAnalysis? {
        guard isSupported else { return nil }
        return try? await analyzer.analyze(image, configuration: .init([.text]))
    }
}
