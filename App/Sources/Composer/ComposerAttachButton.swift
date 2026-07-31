import PhotosUI
import SwiftUI

/// The composer's `+`, and everything it puts on screen.
///
/// Its own view rather than a member of ``MessageComposerView``, because the `+` is
/// the only control in the bar with surfaces of its own — a card, a picker and a
/// notice — and every one of them needs state the rest of the composer has no use
/// for. Keeping them here also keeps the presentation *order* readable, which
/// matters more than it looks: see ``chosenSource``.
///
/// # A bare glyph, not a glass button
///
/// It sits *on* the bar's glass, and a second layer of the material there is the
/// flat grey disc this replaced — glass cannot sample glass (WWDC25 323). Vibrancy
/// is the treatment WWDC25 219 prescribes for exactly this, and it carries its own
/// contrast: symbols over the regular variant flip light-to-dark with the material.
///
/// No disc, so the glyph's box *is* the touch box.
struct ComposerAttachButton: View {
    let attachments: ComposerAttachmentsModel
    /// The touch target, sized by the bar so both its controls agree.
    let hitTarget: CGFloat
    /// Whether the composer had the keyboard when this was pressed — read once, on
    /// press, because by the time a surface is dismissed the answer has changed.
    let isComposerFocused: () -> Bool
    /// Hands the keyboard back, once everything this presented has gone.
    let restoreFocus: () -> Void

    @State private var isShowingMenu = false
    @State private var isShowingPhotosPicker = false
    @State private var isShowingWorkInProgress = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var wasFocusedBeforePresentation = false

    /// What the card was asked for, held until the card has actually gone.
    ///
    /// The card's own button cannot present the picker directly. A modal presented
    /// from inside another modal's own action races that modal's dismissal, and
    /// UIKit resolves the race by dropping one of them — the same failure as a
    /// navigation push from inside a sheet (Part 13). So the choice is recorded,
    /// the card is dismissed, and the picker is presented from the card's
    /// disappearance.
    @State private var chosenSource: ComposerAttachmentSource?

    var body: some View {
        Button(action: presentMenu) {
            Image(systemName: "plus")
                .font(.hiveSymbol(.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: hitTarget, height: hitTarget)
        }
        // The app's own press treatment rather than a new one — and safe under the
        // composer's no-animation rule, because the `.animation` inside it is bound
        // to `configuration.isPressed` and scoped to the label, so it cannot reach
        // the bar's height or catch a keyboard-driven layout pass. It also supplies
        // the `contentShape` that makes the whole frame tappable rather than just
        // the glyph.
        .buttonStyle(.hivePress)
        .accessibilityLabel("More options")
        // Anchored to this control with the arrow beneath the card, so it opens
        // upward over the conversation. `presentationCompactAdaptation(.popover)`
        // is what stops iPhone adapting it into a sheet from the bottom of the
        // screen, which would cover the bar it belongs to and take the keyboard
        // down with it.
        .popover(isPresented: $isShowingMenu, arrowEdge: .bottom) {
            ComposerAttachmentMenu(choose: choose)
                .presentationCompactAdaptation(.popover)
        }
        // Bounded by what is left rather than by the cap, so the picker itself stops the
        // author at five instead of letting them choose pictures that are then dropped.
        //
        // `max(1, …)` guards a real trap: a `maxSelectionCount` of **0 means unlimited**, so a
        // full composer would open an unbounded picker. The zero case never reaches here —
        // ``present(_:)`` refuses it — and this is the belt to that bracing.
        .photosPicker(
            isPresented: $isShowingPhotosPicker,
            selection: $pickedPhotos,
            maxSelectionCount: max(1, attachments.remainingCapacity),
            matching: .images
        )
        .onChange(of: pickedPhotos) { _, items in attach(items) }
        // Fired by the card's *disappearance* — the earliest moment another modal
        // may be presented without racing it away. A card dismissed without a
        // choice (tapped outside) falls through to the focus handover instead.
        .onChange(of: isShowingMenu) { _, isPresented in
            guard !isPresented else { return }
            if let source = chosenSource {
                chosenSource = nil
                present(source)
            } else {
                restoreFocusIfSettled()
            }
        }
        .onChange(of: isShowingPhotosPicker) { _, isPresented in
            guard !isPresented else { return }
            restoreFocusIfSettled()
        }
        .alert("WIP", isPresented: $isShowingWorkInProgress) {
            Button("OK", role: .cancel) {}
        }
        // Restored on *dismissal*, not from the OK action: an alert dismissed any
        // other way (a hardware Escape, a programmatic dismissal) would otherwise
        // leave the author mid-draft with no keyboard, and restoring after the
        // alert's own window has gone is also the moment `becomeFirstResponder`
        // can actually succeed.
        .onChange(of: isShowingWorkInProgress) { _, isPresented in
            guard !isPresented else { return }
            restoreFocusIfSettled()
        }
    }

    // MARK: - Presenting

    private func presentMenu() {
        wasFocusedBeforePresentation = isComposerFocused()
        chosenSource = nil
        isShowingMenu = true
    }

    /// Records the choice and closes the card. What the choice *does* happens in
    /// ``present(_:)``, once the card is actually gone.
    private func choose(_ source: ComposerAttachmentSource) {
        chosenSource = source
        isShowingMenu = false
    }

    /// Acts on a choice, now that the card presenting it has been dismissed.
    private func present(_ source: ComposerAttachmentSource) {
        guard source.isBuilt else {
            isShowingWorkInProgress = true
            return
        }
        switch source {
        case .photos:
            // Full already: say so rather than opening a picker whose every choice would be
            // refused on the way back.
            guard attachments.remainingCapacity > 0 else {
                attachments.reportAtCapacity()
                restoreFocusIfSettled()
                return
            }
            isShowingPhotosPicker = true
        case .camera: isShowingWorkInProgress = true
        }
    }

    /// Hands a pick to the model and empties the picker's own selection, so
    /// choosing the same photo again is a second attachment rather than nothing.
    private func attach(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedPhotos = []
        attachments.add(items)
    }

    /// Hands the keyboard back to an author who had it before something was put in
    /// front of them.
    ///
    /// One function for all three surfaces, because they chain: the card dismisses
    /// to open the picker, and only the last one to go should restore anything. The
    /// flag is consumed, so the intermediate dismissals in that chain are no-ops
    /// and the final one does the work.
    private func restoreFocusIfSettled() {
        guard wasFocusedBeforePresentation, !isShowingMenu, !isShowingPhotosPicker,
              !isShowingWorkInProgress, chosenSource == nil
        else { return }
        wasFocusedBeforePresentation = false
        restoreFocus()
    }
}
