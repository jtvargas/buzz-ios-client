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

    var body: some View {
        List {
            Section {
                ForEach(history.terms) { recent in
                    RecentSearchRow(recent: recent) { onPick(recent.term) }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            // One term at a time, next to `Clear` for all of them. A history
                            // is only useful if the reader can keep the embarrassing search
                            // out of it without throwing the other thirty-nine away.
                            Button("Delete", role: .destructive) {
                                history.remove(recent.term)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recent searches")
                        .font(.hive(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { history.clear() }
                        .font(.hive(.subheadline, weight: .semibold))
                        .buttonStyle(.hiveNoPress)
                }
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The gesture that puts the keyboard away here, since these rows own their own taps.
        .scrollDismissesKeyboard(.immediately)
    }
}

/// One remembered term.
private struct RecentSearchRow: View {
    let recent: RecentSearch
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.hiveSymbol(.body))
                    .foregroundStyle(.secondary)
                Text(recent.term)
                    .font(.hive(.body, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                MessageTimestampView(date: recent.searchedAt, font: .hive(.caption))
                Image(systemName: "chevron.right")
                    .font(.hiveSymbol(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.hivePress(.row))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Searches for this again")
    }
}
