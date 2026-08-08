import SwiftUI

/// What the search screen shows when nothing has been asked yet — the terms this reader has
/// searched before, newest first.
///
/// # Why this replaces the placeholder rather than sitting under it
///
/// The empty search screen had one job before: to say what the screen is for. It only ever
/// needed saying once. After that the same space is the best real estate on the tab — it is
/// what a reader sees every single time they open search, and the thing they want most often
/// is the search they just did.
///
/// The illustrated placeholder is still there for the one reader who has no history yet, which
/// is the only time it tells them anything.
struct RecentSearchesView: View {
    let history: SearchHistory
    /// Run a term again. The field takes it too, so the reader can edit from where they were
    /// rather than retyping.
    let onPick: (String) -> Void

    /// The one horizontal inset on this screen.
    ///
    /// Shared by the heading, every row and the rules between them, because they are one
    /// column and a reader sees any disagreement between them as a wobble. It was the header's
    /// zeroed `listRowInsets` that put `Recent searches` against the left edge and pushed
    /// `Clear` off the right one — a `List` gives a row sensible insets and that took them
    /// away without putting anything back.
    private static let gutter: CGFloat = 20

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                ForEach(history.terms) { recent in
                    RecentSearchRow(
                        recent: recent,
                        onPick: { onPick(recent.term) },
                        onForget: { history.remove(recent.term) }
                    )
                    .padding(.horizontal, Self.gutter)
                    if recent.id != history.terms.last?.id {
                        // Inset to the text rather than run edge to edge: a rule that reaches
                        // the bezel divides the screen, and these rows are one group.
                        Divider()
                            .padding(.leading, Self.gutter + RecentSearchRow.textInset)
                            .padding(.trailing, Self.gutter)
                    }
                }
            }
            .padding(.top, 4)
        }
        // A `List` would have been fewer lines and is what this started as. It is the wrong
        // container here: its row insets, its separator insets and its section-header insets
        // are three different numbers that all had to be overridden to one, and overriding
        // them is what broke the padding in the first place. A stack has one.
        //
        // The swipe-to-forget went with it — `swipeActions` is a `List` affordance. Forgetting
        // one term lives on the row's own hold instead, which is where the app puts every
        // other per-row action.
        .scrollDismissesKeyboard(.immediately)
    }

    private var header: some View {
        HStack {
            Text("Recent searches")
                .font(.hive(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clear") { history.clear() }
                .font(.hive(.subheadline, weight: .semibold))
                .buttonStyle(.hiveNoPress)
        }
        .padding(.horizontal, Self.gutter)
        .padding(.bottom, 6)
    }
}

/// One remembered term.
private struct RecentSearchRow: View {
    let recent: RecentSearch
    let onPick: () -> Void
    /// Drop this one term. Next to `Clear` for all of them: a history is only useful if the
    /// reader can take one search out of it without throwing the other thirty-nine away.
    let onForget: () -> Void

    /// How far the term's own text sits from the row's leading edge — the glyph plus the gap
    /// after it. Named because the separator below the row lines up with the text and not with
    /// the glyph, and two numbers that have to agree should be one.
    static let textInset: CGFloat = 32

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 0) {
                Image(systemName: "clock")
                    .font(.hiveSymbol(.body))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.textInset, alignment: .leading)
                Text(recent.term)
                    .font(.hive(.body, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                MessageTimestampView(date: recent.searchedAt, font: .hive(.caption))
                Image(systemName: "chevron.right")
                    .font(.hiveSymbol(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.hivePress(.row))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Searches for this again")
        // The row is one target, so the hold is bounded by construction — the rule that a
        // `.contextMenu` inside a `List` row cannot be narrowed does not apply here, and this
        // is no longer in a `List` anyway.
        .contextMenu {
            Button("Forget", systemImage: "trash", role: .destructive, action: onForget)
        }
    }
}
