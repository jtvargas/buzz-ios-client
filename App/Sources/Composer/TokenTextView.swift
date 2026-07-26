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
        view.accessibilityLabel = placeholder
        context.coordinator.render(document, in: view, selection: 0)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != document.text {
            let selection = min(view.selectedRange.location, (document.text as NSString).length)
            context.coordinator.render(document, in: view, selection: selection)
        }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
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
        let maximum = lineHeight * 5 + 18
        return CGSize(width: width, height: min(max(measured.height, minimum), maximum))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TokenTextView

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
            parent.document = next
            render(next, in: textView, selection: cursor)
            return false
        }

        func textViewDidBeginEditing(_: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func render(_ document: MentionDraft, in view: UITextView, selection: Int) {
            let baseFont = UIFont.preferredFont(forTextStyle: .body)
            let attributed = NSMutableAttributedString(
                string: document.text,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: UIColor.label,
                ]
            )
            for token in document.tokens where NSMaxRange(token.range) <= attributed.length {
                attributed.addAttributes([
                    .foregroundColor: UIColor.tintColor,
                    .font: UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                    Self.mentionPubkey: token.pubkey,
                ], range: token.range)
            }
            view.attributedText = attributed
            view.selectedRange = NSRange(location: min(selection, attributed.length), length: 0)
            view.isScrollEnabled = view.contentSize.height
                > baseFont.lineHeight * 5 + view.textContainerInset.top + view.textContainerInset.bottom
        }

        private static let mentionPubkey = NSAttributedString.Key("HiveMentionPubkey")
    }
}
