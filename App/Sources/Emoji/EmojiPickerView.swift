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
    /// Whether the bottom field holds the keyboard — the one thing that decides whether the
    /// dismiss button is there to be pressed.
    @FocusState private var isSearchFocused: Bool

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

    /// The search field, drawn rather than asked for, with the button that gives the
    /// keyboard back.
    ///
    /// `.searchable` cannot go here — it places itself, and every placement it offers is a
    /// bar at the top. Drawing it by hand means drawing back everything the system field
    /// gave for free, and it gave two things that had to be re-made by name: the **glass**,
    /// and the **cancel button beside it**. A hand-built field that keeps the keyboard with
    /// no way to put it down is the worst of the two arrangements.
    ///
    /// The shell is ``glassEffect(_:in:)`` on a capsule floating clear of the grid with
    /// nothing opaque behind it, so glyphs scrolling underneath refract instead of being
    /// hidden by a slab — ``MessageComposerView``'s shape, down to the 12/8 float. Both
    /// pieces of glass sit in one `GlassEffectContainer` so they are sampled together and
    /// read as one control rather than two lozenges that happen to be adjacent.
    private var bottomSearchBar: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                searchField
                if isSearchFocused {
                    dismissKeyboardButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.25), value: isSearchFocused)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.hiveSymbol(.footnote))
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $query)
                .font(.hive(.body))
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // The keyboard's own return key does what the button does, for anyone who
                // never looks away from it.
                .onSubmit { isSearchFocused = false }
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
        .padding(.horizontal, 14)
        // The platform minimum, and what makes this read as a search bar rather than as a
        // text field someone put at the bottom.
        .frame(minHeight: 44)
        // `.interactive()` because this one is tapped: the glass answers the finger the way
        // every other control in the app does.
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
    }

    /// Puts the keyboard away without discarding the search.
    ///
    /// `.searchable`'s Cancel clears the field as it dismisses, because there the search is
    /// the screen and leaving is abandoning it. Here the search *result* is the grid behind
    /// the keyboard: someone types `cat`, then wants the keyboard gone so they can see and
    /// tap what they found. Clearing on dismiss would delete the thing they were reaching
    /// for. The `✕` inside the field is what clears; this only unfocuses.
    private var dismissKeyboardButton: some View {
        Button {
            isSearchFocused = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.hiveSymbol(.footnote, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Hide keyboard")
        // From the trailing edge, so it reads as sliding out from under the field rather
        // than appearing on top of the grid.
        .transition(.move(edge: .trailing).combined(with: .opacity))
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
