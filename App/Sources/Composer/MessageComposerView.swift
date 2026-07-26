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
            if !autocomplete.suggestions.isEmpty {
                MentionAutocompletePanel(
                    suggestions: autocomplete.suggestions,
                    onSelect: select
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
                .onTapGesture { autocomplete.isComposerFocused = true }
                .composerGlass(interactive: true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.18), value: autocomplete.suggestions.isEmpty)
        .onChange(of: document) { _, newValue in
            autocomplete.update(for: newValue)
            onTextChange(newValue.text)
        }
        .task {
            autocomplete.update(for: document)
            await autocomplete.run()
        }
    }

    private func select(_ candidate: MentionCandidateProfile) {
        autocomplete.select(candidate, in: &document)
        autocomplete.isComposerFocused = true
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

private struct MentionAutocompletePanel: View {
    let suggestions: [MentionCandidateProfile]
    let onSelect: (MentionCandidateProfile) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions) { candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(
                                url: candidate.picture.flatMap(URL.init(string:)),
                                seed: candidate.pubkey,
                                initial: String(candidate.displayName.prefix(1)).uppercased(),
                                size: 32
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(candidate.isAgent ? "Agent" : (candidate.secondaryLabel ?? "Member"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if candidate.isAgent {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Agent")
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 288)
        .composerGlass(interactive: false)
        .accessibilityLabel("Mention suggestions")
    }
}

private extension View {
    @ViewBuilder
    func composerGlass(interactive: Bool) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            } else {
                glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: interactive ? 22 : 18)
            )
        }
    }
}
