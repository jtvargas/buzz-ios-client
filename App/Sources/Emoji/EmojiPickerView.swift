import SwiftUI

/// The full emoji grid: reached from the actions sheet's palette when none of the five
/// quick reactions is the one someone meant, and from the avatar editor when the glyph is
/// going to be someone's face.
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
    /// Where the search field sits.
    enum SearchPlacement {
        /// The navigation bar's search drawer — the platform's own answer, and the right
        /// one when the picker *is* the screen.
        case navigationBar
        /// A bar pinned under the grid. For the avatar editor, where the search drawer
        /// would sit at the far end of the screen from the grid it filters, with the
        /// preview and the colour row between them.
        case bottomBar
    }

    /// Where to put the search field. Defaults to the platform placement, so the actions
    /// sheet — which presents this picker as a whole screen — is unaffected.
    var searchPlacement: SearchPlacement = .navigationBar

    /// The chosen emoji. The caller decides what that means: the actions sheet means a
    /// reaction, the avatar editor means a picture. The cell plays the reaction haptic
    /// either way — it is the feedback for "that glyph is now yours", which both are.
    let onSelect: (String) -> Void

    @State private var query = ""

    /// The cell, and so the touch target: the platform's 44pt minimum, never smaller.
    private static let cell: CGFloat = 44

    @ViewBuilder
    var body: some View {
        switch searchPlacement {
        case .navigationBar:
            grid
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search emoji"
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .bottomBar:
            // An inset rather than a sibling in a `VStack`: the grid then keeps the bar's
            // height as scroll padding, so the last row of glyphs can be scrolled clear of
            // it instead of resting permanently underneath.
            grid.safeAreaInset(edge: .bottom, spacing: 0) { bottomSearchBar }
        }
    }

    private var grid: some View {
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
        .overlay { emptyState }
    }

    /// The search field, drawn rather than asked for.
    ///
    /// `.searchable` cannot go here — it places itself, and every placement it offers is in
    /// a bar at the top. So this is a plain field in the shape the platform draws one, on
    /// the same `.bar` material the pinned section headings use.
    private var bottomSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.hiveSymbol(.footnote))
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $query)
                .font(.hive(.body))
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hiveSymbol(.footnote))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
    }

    private func cell(_ emoji: String) -> some View {
        Button {
            // Here and not in the applier `onSelect` hands the emoji to: that applier is
            // shared with the sheet's quick-reaction row, which plays its own, so a play
            // there would arrive twice for one choice.
            HiveHaptics.play(.reaction)
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
        .buttonStyle(.hivePress)
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
