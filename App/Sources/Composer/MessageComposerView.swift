import BuzzKit
import SwiftUI

/// The shared channel/thread composer: one large focus target, an attributed
/// mention editor, an indexed autocomplete panel, and native Liquid Glass chrome.
struct MessageComposerView: View {
    @Binding var document: MentionDraft
    @Bindable var autocomplete: MentionAutocompleteModel
    let placeholder: String
    let sendAccessibilityLabel: String
    var onTextChange: (String) -> Void = { _ in }
    let onSend: () -> Void

    private var canSend: Bool {
        !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TokenTextView(
                        document: $document,
                        isFocused: Binding(
                            get: { autocomplete.isComposerFocused },
                            set: { autocomplete.isComposerFocused = $0 }
                        ),
                        placeholder: placeholder
                    )
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        if document.text.isEmpty {
                            Text(placeholder)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 12)
                                .padding(.top, 9)
                                .allowsHitTesting(false)
                        }
                    }

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .clipShape(.circle)
                    .disabled(!canSend)
                    .accessibilityLabel(sendAccessibilityLabel)
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(.rect(cornerRadius: 22))
                .onTapGesture {
                    if !autocomplete.isComposerFocused {
                        autocomplete.isComposerFocused = true
                    }
                }
                .composerGlass(interactive: true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: document) { _, newValue in
            autocomplete.update(for: newValue)
            onTextChange(newValue.text)
        }
        .task {
            autocomplete.update(for: document)
            await autocomplete.run()
        }
    }

    private func send() {
        onSend()
        autocomplete.dismiss()
        // The container is also a focus target. Resign on the next run-loop turn
        // so a tap that lands on Send cannot let the container gesture reopen it.
        DispatchQueue.main.async {
            autocomplete.isComposerFocused = false
        }
    }
}

private extension View {
    @ViewBuilder
    func composerGlass(interactive: Bool) -> some View {
        if #available(iOS 26, *), interactive {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}
