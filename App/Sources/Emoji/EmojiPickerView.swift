import SwiftUI

/// The full emoji grid, reached from the actions sheet's palette when none of the five
/// quick reactions is the one someone meant.
///
/// A grid of plain glyphs with section headings and a search field, which is what every
/// picker on the platform is: there is no system emoji picker a view can present — the only
/// one iOS ships is a *keyboard*, reachable solely by a text field becoming first responder,
/// and it reports its choice as typed text rather than as a selection. So a reaction picker
/// is drawn, not summoned.
///
/// The headings pin, because scrolling several hundred glyphs with nothing anchored leaves
/// no way to tell where you are.
struct EmojiPickerView: View {
    /// The chosen emoji. The caller decides what that means — here it is always a reaction.
    let onSelect: (String) -> Void

    @State private var query = ""

    /// The cell, and so the touch target: the platform's 44pt minimum, never smaller.
    private static let cell: CGFloat = 44

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.cell), spacing: 8)],
                spacing: 8,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(EmojiCatalog.sections(matching: query)) { section in
                    Section {
                        ForEach(section.emoji, id: \.self, content: cell)
                    } header: {
                        header(section.name)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search emoji"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .overlay { emptyState }
    }

    private func cell(_ emoji: String) -> some View {
        Button {
            onSelect(emoji)
        } label: {
            // Sized against `.title` rather than fixed, so the grid grows with Dynamic Type
            // like everything else. The face named is Inter and the glyph drawn is not:
            // Inter has no emoji, so CoreText falls through to the system's colour emoji
            // font. The point size is the whole contribution, and asking for it through
            // `.hive` is what keeps this from reading as a call site the sweep missed.
            Text(emoji)
                .font(.hive(fixedSize: 30, relativeTo: .title))
                .frame(width: Self.cell, height: Self.cell)
                .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        // The glyph is unpronounceable, so the name behind it is the label.
        .accessibilityLabel(EmojiCatalog.unicodeName(of: emoji))
    }

    private func header(_ name: String) -> some View {
        Text(name)
            .font(.hive(.footnote, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            // A material behind a pinned heading, so the glyphs scrolling under it do not
            // read through the label. A `LazyVGrid` section header spans the whole row of
            // its own accord, so there is no column count to declare.
            .background(.bar)
    }

    @ViewBuilder
    private var emptyState: some View {
        if EmojiCatalog.sections(matching: query).isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}
