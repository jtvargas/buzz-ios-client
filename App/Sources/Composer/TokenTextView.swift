import SwiftUI
import UIKit

/// UIKit's attributed editor bridged into SwiftUI so an inserted mention can be
/// visibly styled and edited as one atomic unit.
struct TokenTextView: UIViewRepresentable {
    @Binding var document: MentionDraft
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        view.keyboardDismissMode = .interactive
        view.accessibilityLabel = placeholder
        context.coordinator.render(document, in: view, selection: 0)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.renderedDocument != document {
            let selection = min(view.selectedRange.location, (document.text as NSString).length)
            context.coordinator.render(document, in: view, selection: selection)
        }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator, coordinator.parent.isFocused,
                      !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let minimum = lineHeight + 18
        let maximum = lineHeight * 6 + 18
        // Keep the mode stable at the six-line boundary. Without hysteresis,
        // UITextView can report the clamped height after scrolling turns on and
        // flip scrolling off again in the next layout pass.
        let shouldScroll = uiView.isScrollEnabled
            ? measured.height >= maximum - 0.5
            : measured.height > maximum + 0.5
        if uiView.isScrollEnabled != shouldScroll {
            uiView.isScrollEnabled = shouldScroll
            uiView.alwaysBounceVertical = shouldScroll
        }
        return CGSize(width: width, height: min(max(measured.height, minimum), maximum))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TokenTextView
        private(set) var renderedDocument: MentionDraft?
        private var pendingNativeDocument: MentionDraft?

        init(_ parent: TokenTextView) {
            self.parent = parent
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            var next = parent.document
            let cursor = next.replaceCharacters(in: range, with: text)
            if parent.document.requiresAtomicEdit(in: range) {
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
            if let pendingNativeDocument {
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

        func textViewDidBeginEditing(_: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func render(_ document: MentionDraft, in view: UITextView, selection: Int) {
            let attributed = NSMutableAttributedString(
                string: document.text,
                attributes: baseAttributes
            )
            view.attributedText = attributed
            applyAttributes(document, in: view)
            view.selectedRange = NSRange(location: min(selection, attributed.length), length: 0)
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
            for token in document.tokens where NSMaxRange(token.range) <= storage.length {
                storage.addAttributes([
                    .foregroundColor: UIColor.tintColor,
                    .font: mentionFont,
                    Self.mentionPubkey: token.pubkey,
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

        private static let mentionPubkey = NSAttributedString.Key("HiveMentionPubkey")
    }
}
