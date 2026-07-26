import BuzzKit
import SwiftUI

/// The mention suggestion panel, hosted **over** the message list rather than inside
/// the composer.
///
/// Two reasons it does not live in the composer's own stack. A panel inside the
/// bottom bar re-insets the message list on every keystroke that changes the result
/// count; and animating a tall bar's height is a known iOS 26 stall. As a floating
/// accessory it costs the list nothing and can grow to its results freely.
///
/// Renders nothing at all when there is nothing to suggest, so a call site can place
/// it unconditionally.
struct MentionSuggestionsView: View {
    @Binding var document: MentionDraft
    @Bindable var autocomplete: MentionAutocompleteModel

    /// The tallest the panel grows before its own scrolling takes over. Height below
    /// that is the results' own — never a fixed frame.
    private static var maxHeight: CGFloat { 240 }

    var body: some View {
        if !autocomplete.suggestions.isEmpty {
            panel
                .transition(.opacity.combined(with: .offset(y: 8)))
                .animation(.smooth(duration: 0.16), value: autocomplete.suggestions.count)
        }
    }

    private var panel: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(autocomplete.suggestions) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        MentionSuggestionRow(candidate: candidate)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        // The panel scrolls its own results and must never dismiss the keyboard —
        // that mode is inherited from the enclosing list otherwise.
        .scrollDismissesKeyboard(.never)
        // Content-sized up to the ceiling, then scrolling: the height follows the
        // number of results instead of reserving a fixed slab.
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .suggestionGlass()
        .accessibilityLabel("Mention suggestions")
    }

    private func select(_ candidate: MentionCandidateProfile) {
        autocomplete.select(candidate, in: &document)
        autocomplete.isComposerFocused = true
    }
}

/// One suggestion: avatar, name, and the quiet second line that says what kind of
/// identity it is.
private struct MentionSuggestionRow: View {
    let candidate: MentionCandidateProfile

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                url: candidate.picture.flatMap(URL.init(string:)),
                seed: candidate.pubkey,
                monogram: EntityNames.initials(from: candidate.displayName),
                size: 30
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.displayName)
                    .font(.subheadline.weight(.medium))
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
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Agent")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
}

private extension View {
    /// The panel's own surface: glass, not an opaque slab, so it reads as part of the
    /// composer it sits above.
    @ViewBuilder
    func suggestionGlass() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
