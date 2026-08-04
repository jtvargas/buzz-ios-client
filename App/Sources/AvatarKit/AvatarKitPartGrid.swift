import SwiftUI

/// What one layer offers, as a grid of the avatars it would make.
///
/// # Why a grid, when this was a row
///
/// The row held thirty-three hairstyles four at a time. Everything wrong with that follows
/// from the arithmetic: eight swipes to reach the end, no way to tell from any one of them how
/// far along it was, and — because it lived under a second horizontal scroller of layer chips
/// — two sideways gestures stacked with nothing on screen fixed enough to be a landmark. Four
/// at a time is also fewer than the eye can compare, so choosing meant remembering.
///
/// Sixteen at a time in a vertical grid answers all of it. The scroll is the axis the phone
/// has an indicator for, so "how much is left" is drawn rather than guessed; the layer chips
/// above no longer scroll at all, so the only gesture on the screen is one; and the preview,
/// the chips and the choices are still on screen together — which was the row's own argument
/// for existing, and it survives the change.
///
/// # Why every cell is the whole avatar
///
/// The row drew each part *alone*, cropped to its category's window. That is what a picker of
/// parts looks like, and it is not what a reader is choosing: the eight faces differ only in
/// ear and jaw, which is invisible without the eyes and hair that sit on them, and a mouth
/// floating in an empty box says nothing about the face it is going onto. Here a cell is the
/// avatar being built with exactly one layer swapped, still cropped to the category's window —
/// so a mouth cell is a mouth *on this chin*, and the difference between two of them is the
/// only thing in the cell that differs. It costs sixteen composites a screen, which is why
/// ``AvatarKitThumbnails`` exists.
struct AvatarKitPartGrid: View {
    let part: AvatarKitPart
    @Binding var avatar: AvatarKitAvatar
    var insets: CGFloat = 20

    /// Four across on a phone, fixed rather than adaptive. The app is portrait-only, so the
    /// width is known; at 402pt it makes an 83pt cell, which is large enough to tell two
    /// hairstyles apart and small enough that four rows are in view.
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 4)
    private static let spacing: CGFloat = 10
    private static let cornerRadius: CGFloat = 14

    /// One cell. `absent` rather than `none`, because a case called `none` is shadowed by
    /// `Optional.none` at exactly the comparisons this type exists to make.
    private enum Cell: Hashable {
        case absent
        case option(Int)

        var index: Int? {
            switch self {
            case .absent: nil
            case let .option(index): index
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: Self.columns, spacing: Self.spacing) {
                    ForEach(cells, id: \.self, content: cell)
                }
                .padding(.horizontal, insets)
                .padding(.top, 2)
                // Room under the last row, so a grid scrolled to its end stops clear of the
                // Shuffle button rather than against it.
                .padding(.bottom, 10)
            }
            // Shown, not hidden. It is the answer to "how far through am I" that the row it
            // replaced had no way to give at all.
            .scrollIndicators(.visible)
            // After layout rather than in `onAppear`, which runs before the lazy grid knows
            // where anything is. Opening a layer thirty options long on option one and
            // leaving the reader to find the one they are wearing is the whole reason.
            .task { proxy.scrollTo(selected, anchor: .center) }
        }
        // A fresh grid per layer. The cells of one layer have nothing in common with the cells
        // of the next, and identifying them by position would reuse a hair's view for a mouth
        // — which is a frame of the wrong artwork every time a chip is tapped.
        .id(part)
        // Every cell of this layer drawn ahead of the scroll that would otherwise draw them,
        // restarted whenever the avatar underneath them changes. See
        // ``AvatarKitThumbnails/prewarm(_:)`` for why this is not left to the cells.
        .task(id: avatar) { await AvatarKitThumbnails.prewarm(prewarmOrder) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(part.title)
    }

    // MARK: - What is in the grid

    private var optionCount: Int {
        part == .background ? AvatarKitBackground.allCases.count : part.options.count
    }

    /// The cells, with "none" first where a layer can be absent — first because taking a layer
    /// off is a thing a reader goes looking for, and last is where things go to not be found.
    private var cells: [Cell] {
        let options = (0 ..< optionCount).map(Cell.option)
        return part.allowsNone ? [.absent] + options : options
    }

    private var selected: Cell {
        if let index = part.selection(in: avatar) { .option(index) } else { .absent }
    }

    /// The avatar cell `cell` is offering: this one, with this layer swapped for that option.
    private func candidate(_ cell: Cell) -> AvatarKitAvatar {
        var next = avatar
        part.apply(cell.index, to: &next)
        return next
    }

    private func thumbnail(_ cell: Cell) -> AvatarKitThumbnail {
        AvatarKitThumbnail(avatar: candidate(cell), window: part.window)
    }

    /// What to draw first: the selection, then outwards from it.
    ///
    /// The grid opens centred on the selection, so that is what is under the reader's eye
    /// while the drawing happens, and a scroll from there goes to a neighbour before it goes
    /// anywhere else. Drawing in catalogue order would fill the screen last on any layer whose
    /// selection is past the fourth row.
    private var prewarmOrder: [AvatarKitThumbnail] {
        let all = cells
        let start = all.firstIndex(of: selected) ?? 0
        return all.indices
            .sorted { abs($0 - start) < abs($1 - start) }
            .map { thumbnail(all[$0]) }
    }

    // MARK: - A cell

    private func cell(_ cell: Cell) -> some View {
        let isSelected = cell == selected
        return Button {
            // The platform's own "an item was chosen from a list", which is what this is.
            HiveHaptics.play(.suggestionPicked)
            avatar = candidate(cell)
        } label: {
            AvatarKitThumbnailView(thumbnail: thumbnail(cell))
                // Behind the picture, so a cell that has not been drawn yet is an empty tile
                // in the grid rather than a hole in it.
                .background(Color(.tertiarySystemFill))
                .clipShape(.rect(cornerRadius: Self.cornerRadius))
                .overlay { border(isSelected: isSelected) }
                .overlay(alignment: .bottom) { caption(cell) }
                .overlay(alignment: .topTrailing) { if isSelected { tick } }
                .contentShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: Self.cornerRadius)))
        .id(cell)
        .accessibilityLabel(label(cell))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// The selection, said three times.
    ///
    /// A ring alone was what the row had, and in a grid of sixteen tiles a two-point ring on one
    /// of them is a thing you find rather than a thing you see. The tick is the second saying,
    /// and it is also the one that survives a reader who cannot tell the accent from the
    /// separator: the ring is a colour change and the badge is a shape appearing.
    ///
    /// The third is the dark hairline *inside* the accent, and it is not decoration. A cell
    /// carries the avatar's own ground, one of the nine is a yellow within a few degrees of this
    /// app's amber, and a picture photographed on it showed the ring all but gone. A thumbnail
    /// can be any colour, so the ring cannot rely on contrasting with one — the hairline gives it
    /// an edge of its own to sit against whatever is behind it.
    private func border(isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.cornerRadius - Self.ringWidth)
                    .strokeBorder(.black.opacity(0.55), lineWidth: 1.5)
                    .padding(Self.ringWidth)
            }
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(.separator),
                    lineWidth: isSelected ? Self.ringWidth : 1
                )
        }
    }

    private static let ringWidth: CGFloat = 3

    /// The badge, with a shadow for the same reason the ring has a hairline: white on amber on
    /// a yellow avatar is one colour on another on a third that is nearly the second.
    private var tick: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.hiveSymbol(.subheadline, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .padding(4)
    }

    /// The word on the cell that takes a layer away.
    ///
    /// It needs one. Drawn as the avatar without its hair, the "none" cell is a correct
    /// picture of the answer and an ambiguous picture of the *offer* — among thirty-two
    /// hairstyles a bald head reads as the thirty-third rather than as the way out. The
    /// transparent ground has the same problem behind checks, so it gets the same word.
    @ViewBuilder
    private func caption(_ cell: Cell) -> some View {
        if isNone(cell) {
            Text("None")
                .font(.hive(.caption2, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7), in: .capsule)
                .padding(.bottom, 6)
        }
    }

    /// Whether `cell` is this layer's way out — an absent layer, or the ground that is not a
    /// colour. The two are spelled differently in the model and mean the same thing here.
    private func isNone(_ cell: Cell) -> Bool {
        switch cell {
        case .absent: true
        case let .option(index): part == .background && index == AvatarKitBackground.transparent.rawValue
        }
    }

    // MARK: - Names

    private func label(_ cell: Cell) -> String {
        guard case let .option(index) = cell else { return "None" }
        if part == .background {
            return AvatarKitBackground(rawValue: index)?.title ?? "Colour"
        }
        // The artwork has no names, so the position is the only true thing to say about it.
        return "\(part.title) \(index + 1)"
    }
}
