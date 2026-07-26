import SwiftUI
import UIKit

/// UIKit's attributed editor bridged into SwiftUI so an inserted mention can be
/// visibly styled and edited as one atomic unit.
///
/// # One source of truth for focus
///
/// SwiftUI owns focus. UIKit reports only *user-initiated* changes (a tap, or the
/// keyboard's dismiss key) and applies whatever SwiftUI asks for, synchronously,
/// inside a reconciliation flag so the delegate callbacks cannot write back into
/// observed state during SwiftUI's own update pass. There is no `DispatchQueue.main.async`
/// anywhere here: a deferred `becomeFirstResponder` racing a synchronous
/// `resignFirstResponder` is what let `isFocused` and `isFirstResponder` disagree for
/// a frame, and it detaches the change from SwiftUI's transaction so the keyboard
/// animation and the layout animation run on different clocks.
struct TokenTextView: UIViewRepresentable {
    @Binding var document: MentionDraft
    @Binding var isFocused: Bool
    let placeholder: String
    /// Where the caret went, for a move the text did not cause. Mention completion is
    /// anchored to the caret, and UIKit is the only thing that knows a tap or an arrow
    /// key moved it — an edit carries its own caret in the draft, but a bare selection
    /// change has no edit to carry it.
    var onSelectionChange: (NSRange) -> Void = { _ in }

    /// How tall the composer grows before it scrolls its own text.
    static let maxVisibleLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
        view.textContainer.lineFragmentPadding = 0
        // Permanently scrollable, with no toggle. A `UITextView` *is* a `UIScrollView`,
        // and with `isScrollEnabled == false` its `panGestureRecognizer` is inert, so a
        // drag that starts in the composer is delivered to the enclosing message list
        // instead — the composer dragging the conversation. Keeping the recognizer live
        // means the innermost one always claims a drag that starts here, in the short
        // state as well as the tall one, and the height clamp in `sizeThatFits` is what
        // keeps a short composer from having anything to scroll.
        view.isScrollEnabled = true
        // So a composer shorter than the clamp cannot rubber-band against nothing.
        view.alwaysBounceVertical = false
        // Only visible once there is overflow, which is exactly when it means something.
        view.showsVerticalScrollIndicator = true
        view.contentInsetAdjustmentBehavior = .never
        // `.interactive` would let a drag *inside the composer* dismiss the keyboard,
        // and a cancelled interactive dismissal leaves UIKit and SwiftUI disagreeing
        // about the final keyboard frame. `.none` is UIKit's documented default; the
        // message list owns keyboard dismissal, not the text view.
        view.keyboardDismissMode = .none
        view.accessibilityLabel = placeholder
        // At the end of whatever is already there, not at zero: a draft restored after a
        // failed send arrives non-empty, and `makeUIView` marks it as rendered, so the
        // caret placed here is the one the author gets.
        context.coordinator.render(document, in: view, selection: (document.text as NSString).length)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.renderedDocument != document {
            // The text view's own `selectedRange` still describes the string it last
            // rendered, so it is only a fallback. The draft carries where the caret
            // belongs after the edit that produced it.
            let stale = min(view.selectedRange.location, (document.text as NSString).length)
            coordinator.render(document, in: view, selection: document.preferredCursor ?? stale)
        }
        // Before the view is in a window, `becomeFirstResponder` and
        // `resignFirstResponder` fail *silently*: the call returns without changing
        // anything and without telling anyone. Applying focus then is how the two
        // states start disagreeing, so nothing is applied until there is a window.
        guard view.window != nil else { return }
        if isFocused, !view.isFirstResponder {
            coordinator.reconcilingFocus { _ = view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            coordinator.reconcilingFocus { _ = view.resignFirstResponder() }
        }
    }

    /// Pure: it measures and clamps, and mutates nothing.
    ///
    /// SwiftUI may call this several times in one layout pass with different
    /// proposals, so a UIKit mutation here (the old scroll toggle) both changed
    /// behaviour as a side effect of measurement and could flip back and forth within
    /// a single pass.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let chrome = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let measured = uiView
            .sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
        return CGSize(
            width: width,
            height: Self.clampedHeight(measured: measured, lineHeight: lineHeight, chrome: chrome)
        )
    }

    /// Clamps a measured text height into the one-to-six-line band.
    ///
    /// `measured` already includes the text container's vertical insets, so both
    /// bounds add `chrome` too. Split out and pure so the arithmetic — the growth
    /// floor and the six-line ceiling that hands over to scrolling — is testable
    /// without a view host.
    static func clampedHeight(measured: CGFloat, lineHeight: CGFloat, chrome: CGFloat) -> CGFloat {
        min(max(measured, lineHeight + chrome), lineHeight * maxVisibleLines + chrome)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TokenTextView
        private(set) var renderedDocument: MentionDraft?
        private var pendingNativeDocument: MentionDraft?
        /// True only while a SwiftUI-requested responder change is being applied.
        private var isReconcilingFocus = false
        /// True only while ``render`` is replacing the text view's contents.
        private var isRendering = false

        init(_ parent: TokenTextView) {
            self.parent = parent
        }

        /// Applies a first-responder change SwiftUI asked for.
        ///
        /// The flag suppresses the delegate write-back — UIKit is reporting a change
        /// SwiftUI already knows about, and writing observed state back during
        /// SwiftUI's update pass is what made the two disagree. The transaction keeps
        /// the change out of any ambient animation, so the responder change rides the
        /// keyboard's own clock instead of starting a second one.
        func reconcilingFocus(_ body: () -> Void) {
            isReconcilingFocus = true
            defer { isReconcilingFocus = false }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            var next = parent.document
            let cursor = next.replaceCharacters(in: range, with: text)
            if parent.document.requiresAtomicEdit(in: range) {
                // Cleared because UIKit will *not* perform this edit: a pending document
                // left here would be picked up by the next `textViewDidChange` — which
                // may be reporting something else entirely — and applied to the wrong
                // text.
                pendingNativeDocument = nil
                parent.document = next
                render(next, in: textView, selection: cursor)
                return false
            }

            // Let UITextView perform ordinary typing, paste, and multiline edits.
            // Replacing attributedText here used to reset selection and layout on
            // every key, which caused the visible cursor jumps and multiline jank.
            pendingNativeDocument = next
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            let next: MentionDraft
            // The pending document is only trusted when it actually describes what the
            // text view now holds. An edit that passes `shouldChangeTextIn` and is then
            // *not* performed (backspace at position zero is the everyday case) used to
            // strand it here, and the next change — dictation, which never passes through
            // `shouldChangeTextIn` — took this branch and locked the model out of step
            // with the screen for the rest of the draft. Sending then transmitted text
            // the author never saw.
            if let pendingNativeDocument, pendingNativeDocument.text == textView.text {
                next = pendingNativeDocument
            } else {
                // Defensive reconciliation for system-originated edits that do not
                // pass through shouldChangeTextIn (dictation is the common case).
                var reconciled = parent.document
                let cursor = reconciled.reconcileText(textView.text)
                if reconciled.text != textView.text {
                    parent.document = reconciled
                    render(reconciled, in: textView, selection: cursor)
                    return
                }
                next = reconciled
            }
            pendingNativeDocument = nil
            parent.document = next
            applyAttributes(next, in: textView)
            renderedDocument = next
        }

        /// The caret moved. Reported only when the text view and the published draft
        /// already agree about the text.
        ///
        /// Two things must not reach the model from here. While an edit is in flight
        /// UIKit's selection describes a string the draft has not caught up with, and
        /// acting on it would place the caret in the *previous* text — the edit carries
        /// its own caret a moment later, which is the authoritative one. And a render
        /// sets `selectedRange` itself, from `updateUIView`: writing observed state back
        /// during SwiftUI's own update pass is what this file avoids everywhere else, and
        /// whoever asked for the render already told the model where the caret is.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isRendering, !isReconcilingFocus else { return }
            guard textView.text == parent.document.text else { return }
            parent.onSelectionChange(textView.selectedRange)
        }

        func textViewDidBeginEditing(_: UITextView) {
            guard !isReconcilingFocus else { return }
            parent.isFocused = true
        }

        func textViewDidEndEditing(_: UITextView) {
            guard !isReconcilingFocus else { return }
            parent.isFocused = false
        }

        func render(_ document: MentionDraft, in view: UITextView, selection: Int) {
            isRendering = true
            defer { isRendering = false }
            let attributed = NSMutableAttributedString(
                string: document.text,
                attributes: baseAttributes
            )
            view.attributedText = attributed
            applyAttributes(document, in: view)
            view.selectedRange = NSRange(location: min(selection, attributed.length), length: 0)
            // Setting `selectedRange` does not scroll, and the composer now scrolls its
            // own text past six lines — so a mention inserted or deleted below the fold
            // would leave the caret out of sight.
            view.scrollRangeToVisible(view.selectedRange)
            renderedDocument = document
        }

        private func applyAttributes(_ document: MentionDraft, in view: UITextView) {
            // The common case has no selected mention. UITextView already carries
            // the base typing attributes, so avoid invalidating its whole text
            // storage on every ordinary keystroke.
            guard !document.tokens.isEmpty else {
                view.typingAttributes = baseAttributes
                return
            }
            let storage = view.textStorage
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            if fullRange.length > 0 {
                storage.setAttributes(baseAttributes, range: fullRange)
            }
            // People and channels tint identically: both are resolved references, and
            // a reader should not have to learn two visual languages for them.
            for token in document.tokens where NSMaxRange(token.range) <= storage.length {
                storage.addAttributes([
                    .foregroundColor: UIColor.tintColor,
                    .font: mentionFont,
                    Self.mentionEntity: token.entityID,
                ], range: token.range)
            }
            storage.endEditing()
            view.typingAttributes = baseAttributes
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
        }

        private var mentionFont: UIFont {
            let baseFont = UIFont.preferredFont(forTextStyle: .body)
            return UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        }

        private static let mentionEntity = NSAttributedString.Key("HiveMentionEntity")
    }
}
