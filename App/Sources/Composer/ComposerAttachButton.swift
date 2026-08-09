import PhotosUI
import SwiftUI

/// The composer's `+`, and everything it puts on screen.
///
/// Its own view rather than a member of ``MessageComposerView``, because the `+` is
/// the only control in the bar that presents attachment surfaces — a card, a picker and
/// the inline camera. Keeping their hand-off here also keeps the presentation *order* readable, which
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
    @State private var isShowingFileImporter = false
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

    private var isExpanded: Bool { isShowingMenu || attachments.isCameraPresented }

    var body: some View {
        Button(action: toggleAttachmentSurface) {
            Image(systemName: "plus")
                .font(.hiveSymbol(.body, weight: .semibold))
                .foregroundStyle(.secondary)
                // A `+` turned an eighth of a turn *is* an X, so the control says what a
                // second press will do rather than swapping to a different glyph and
                // hoping the two are read as one thing. One shape, one rotation, and the
                // card and camera share the same open/close state.
                .rotationEffect(.degrees(isExpanded ? 45 : 0))
                // Scoped to this value and to the glyph, which is what keeps it inside the
                // composer's no-animation rule (see ``MessageComposerView``): a rotation is
                // a render transform on a fixed frame, so it cannot change the bar's height
                // or be caught by a keyboard-driven layout pass. An ambient `.animation`
                // here could do both.
                .animation(.snappy(duration: 0.22), value: isExpanded)
                .frame(width: hitTarget, height: hitTarget)
        }
        // The app's own press treatment rather than a new one — and safe under the
        // composer's no-animation rule, because the `.animation` inside it is bound
        // to `configuration.isPressed` and scoped to the label, so it cannot reach
        // the bar's height or catch a keyboard-driven layout pass. It also supplies
        // the `contentShape` that makes the whole frame tappable rather than just
        // the glyph.
        .buttonStyle(.hivePress)
        .accessibilityLabel(attachments.isCameraPresented ? "Close camera" : "More options")
        // Anchored to this control with the arrow beneath the card, so it opens
        // upward over the conversation. `presentationCompactAdaptation(.popover)`
        // is what stops iPhone adapting it into a sheet from the bottom of the
        // screen, which would cover the bar it belongs to and take the keyboard
        // down with it.
        .popover(isPresented: $isShowingMenu, arrowEdge: .bottom) {
            ComposerAttachmentMenu(choose: choose)
                .presentationCompactAdaptation(.popover)
        }
        // The bounding and the hand-off live in the modifier, which the strip's add tile
        // shares — see ``View/composerPhotosPicker(isPresented:selection:attachments:)``.
        // The zero-capacity case never reaches it from here: ``present(_:)`` refuses first.
        .composerPhotosPicker(
            isPresented: $isShowingPhotosPicker,
            selection: $pickedPhotos,
            attachments: attachments
        )
        // `.item` — every type there is — because that is what the official clients
        // offer: the Flutter one opens `file_selector.openFile` with no type groups
        // and lets the relay decide (`mobile/lib/shared/relay/media_upload.dart`).
        // Narrowing it here would make Hive the only client that cannot send a file
        // the others can.
        //
        // `allowsMultipleSelection` is on so a file pick can fill the same five-item
        // message a photo pick can. The cap is applied on the way back rather than
        // here, in ``ComposerAttachmentsModel/add(_:)``, which is the one place that
        // can see what the composer is already holding.
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                attachments.add(urls.map(ComposerFilePick.init(url:)))
            case let .failure(error):
                attachments.report(error)
            }
        }
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
        .onChange(of: isShowingFileImporter) { _, isPresented in
            guard !isPresented else { return }
            restoreFocusIfSettled()
        }
        .onChange(of: attachments.isCameraPresented) { _, isPresented in
            guard !isPresented else { return }
            restoreFocusIfSettled()
        }
    }

    // MARK: - Presenting

    private func toggleAttachmentSurface() {
        if attachments.isCameraPresented {
            HiveHaptics.play(.disclosureToggled)
            attachments.dismissCamera()
        } else {
            presentMenu()
        }
    }

    private func presentMenu() {
        // The one press in the bar that opens something over the conversation, and the
        // glyph's turn into an X is the only other answer it gives — a tick lands at the
        // tap, where the card has not drawn yet. Same entry the sidebar's headings play,
        // because it is the same event: a disclosure opening.
        HiveHaptics.play(.disclosureToggled)
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
        case .camera:
            guard attachments.remainingCapacity > 0 else {
                attachments.reportAtCapacity()
                restoreFocusIfSettled()
                return
            }
            attachments.presentCamera()
        case .files:
            guard attachments.remainingCapacity > 0 else {
                attachments.reportAtCapacity()
                restoreFocusIfSettled()
                return
            }
            isShowingFileImporter = true
        }
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
              !attachments.isCameraPresented, chosenSource == nil
        else { return }
        wasFocusedBeforePresentation = false
        restoreFocus()
    }
}
