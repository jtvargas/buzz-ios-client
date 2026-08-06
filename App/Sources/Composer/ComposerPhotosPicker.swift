import PhotosUI
import SwiftUI

/// The photo library, opened against a composer that has room for what comes back.
///
/// Extracted because there are now two ways into the same picker — the bar's `+` by way of
/// its card, and the `+` tile on the end of the attachment strip — and the arithmetic
/// between them is the part worth having once. Presentation state stays with each caller,
/// because each has its own reason to be watching it: the `+` chains the picker behind a
/// card's dismissal and hands the keyboard back afterwards, and the tile does neither.
///
/// What is shared is the bounding and the hand-off:
///
/// - The picker is bounded by what is *left* rather than by the cap, so the author is
///   stopped at five inside the picker instead of choosing pictures that are then dropped
///   on the way back.
/// - `max(1, …)` guards a real trap: a `maxSelectionCount` of **0 means unlimited**, so a
///   full composer would otherwise open an unbounded picker. Neither caller can reach here
///   at zero — both check first — and this is the belt to that bracing.
/// - The selection is emptied as it is handed over, so choosing the same photo again is a
///   second attachment rather than nothing at all.
extension View {
    func composerPhotosPicker(
        isPresented: Binding<Bool>,
        selection: Binding<[PhotosPickerItem]>,
        attachments: ComposerAttachmentsModel
    ) -> some View {
        photosPicker(
            isPresented: isPresented,
            selection: selection,
            maxSelectionCount: max(1, attachments.remainingCapacity),
            matching: .images
        )
        .onChange(of: selection.wrappedValue) { _, items in
            guard !items.isEmpty else { return }
            selection.wrappedValue = []
            attachments.add(items)
        }
    }
}
