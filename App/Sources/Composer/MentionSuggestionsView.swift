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
        // Focus is part of the condition: dismissing the keyboard with its own hide key
        // leaves the draft (and therefore the suggestions) exactly as they were, and a
        // panel floating over the list with no keyboard and nothing to type into is just
        // in the way.
        if autocomplete.isComposerFocused, !autocomplete.suggestions.isEmpty {
            panel
                .transition(.opacity.combined(with: .offset(y: 8)))
                // Scoped to the panel on purpose. This is the *only* ambient animation in
                // the composer subtree: an ambient `.animation` anywhere near the bar can
                // catch keyboard-driven layout and run the composer's height on a
                // different clock from the keyboard's, which is the reported flicker.
                .animation(.smooth(duration: 0.16), value: autocomplete.suggestions.count)
        }
    }

    private var panel: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(autocomplete.suggestions) { suggestion in
                    Button {
                        select(suggestion)
                    } label: {
                        MentionSuggestionRow(suggestion: suggestion)
                    }
                    // Pressing a suggestion used to answer with nothing at all. A row and
                    // not a control, because a full-width row shrinking away from the
                    // panel's edges reads as a card lifting out of it — and the animation
                    // the style carries is bound to `configuration.isPressed` and scoped to
                    // the label, so it cannot catch a layout pass the way an ambient one can.
                    .buttonStyle(.hivePress(.row))
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

    private func select(_ suggestion: MentionSuggestion) {
        autocomplete.select(suggestion, in: &document)
        autocomplete.isComposerFocused = true
    }
}

/// One suggestion: a leading mark, the name, and the quiet second line that says what
/// kind of thing it is.
///
/// One row for every kind. A person gets their avatar and their resolved display
/// name; a channel gets a `#` glyph in the same footprint and `#name`. Neither ever
/// shows a hex key or a group id.
private struct MentionSuggestionRow: View {
    let suggestion: MentionSuggestion

    /// The avatar/glyph edge, so the two kinds line their text up identically.
    private static var markSize: CGFloat { 30 }

    var body: some View {
        HStack(spacing: 10) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.hive(.subheadline, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(suggestion.secondaryLabel)
                    .font(.hive(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailingBadge
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }

    /// A person reads as their name; a channel reads as it will be inserted, so what
    /// the author picks is exactly what appears in the draft.
    private var title: String {
        switch suggestion.kind {
        case .user: suggestion.label
        case .channel: suggestion.insertionLabel
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch suggestion {
        case let .user(candidate):
            AvatarView(
                url: suggestion.pictureURL,
                seed: candidate.pubkey,
                monogram: EntityNames.initials(from: candidate.displayName),
                size: Self.markSize
            )
        case .channel:
            Image(systemName: "number")
                .font(.hiveSymbol(.footnote, weight: .semibold))
                .foregroundStyle(.tint)
                // Same footprint and corner ratio as ``AvatarView``'s rounded square,
                // so the two kinds of row align without sharing a code path.
                .frame(width: Self.markSize, height: Self.markSize)
                // A quiet tint wash rather than an opaque tile: it sits on glass.
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if suggestion.isAgent {
            Image(systemName: "sparkles")
                .font(.hiveSymbol(.caption))
                .foregroundStyle(.tint)
                .accessibilityLabel("Agent")
        } else if suggestion.isPrivateChannel {
            Image(systemName: "lock")
                .font(.hiveSymbol(.caption))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Private channel")
        }
    }
}

private extension View {
    /// The panel's own surface: glass, not an opaque slab, so it reads as part of the
    /// composer it sits above.
    func suggestionGlass() -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
