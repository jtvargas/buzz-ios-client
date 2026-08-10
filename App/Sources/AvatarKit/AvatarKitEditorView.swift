import SwiftUI

/// The AvatarKit tab: a board of layers, a grid of what the chosen one offers, and the button
/// that rolls all of them at once.
///
/// # Why Shuffle is at the bottom
///
/// It is the control this screen exists for and the one that gets pressed twenty times in a
/// row, so it goes where a thumb already is. The browsing controls go up next to the preview
/// they change, because those are read before they are tapped and the eye is up there anyway.
/// The layout follows the hand, not the hierarchy.
///
/// # Why nothing on this screen scrolls sideways any more
///
/// It had two horizontal scrollers stacked — the layer chips, and under them the options for
/// whichever chip was chosen — and the second of them was thirty-three cells long. Two axes of
/// the same gesture, one nested inside the other's territory, with no fixed landmark between
/// them: at any moment a reader knew neither which layers they had not seen nor how far through
/// this one they were. Both halves are fixed here rather than one. The chips became a board
/// that shows all eight at once and never moves, and the options became a vertical grid, which
/// is the axis a phone draws an indicator for. What is left is one scroll, in the direction the
/// hand expects, under a control surface that stays put.
///
/// # Why this takes a binding rather than the editor's model
///
/// Everything here is one value changing. Handing it the whole model would give a picker access
/// to the photo upload it has no business touching, and would make this view unopenable in
/// isolation.
struct AvatarKitEditorView: View {
    @Binding var avatar: AvatarKitAvatar
    /// Whether the avatar is being drawn and uploaded right now. Shuffling during that would
    /// change the thing being saved out from under the save.
    let isPreparing: Bool
    let errorMessage: String?

    /// Which layer the grid is showing. Face first: it is the one every other choice sits on,
    /// so it is the one a reader looks at first.
    @State private var part: AvatarKitPart

    /// The layer to open on. Defaults to the one this screen has always opened on; named at all
    /// so a fixture can photograph any of the eight without a tap.
    init(
        avatar: Binding<AvatarKitAvatar>,
        isPreparing: Bool,
        errorMessage: String?,
        layer: AvatarKitPart = .head
    ) {
        _avatar = avatar
        self.isPreparing = isPreparing
        self.errorMessage = errorMessage
        _part = State(initialValue: layer)
    }

    /// The margin the board and the grid keep their content within — the sheet's own, so the
    /// first chip lines up with everything else on the screen.
    private static let insets: CGFloat = 20

    var body: some View {
        VStack(spacing: 12) {
            board
            AvatarKitPartGrid(part: part, avatar: $avatar, insets: Self.insets)
            status
            shuffleButton
        }
        // While the avatar is being drawn and uploaded, nothing here may change it: the picture
        // on its way to the relay is of the combination that was on screen when Done was
        // pressed, and a shuffle landing mid-flight would save a face nobody chose.
        .disabled(isPreparing)
        // The tiles this screen drew are worth tens of megabytes and are worth nothing to
        // anyone else — every other surface draws a *finished* avatar, never a part. Handing
        // them back on the way out is why the cache is an `NSCache` and not a dictionary;
        // ``AvatarKitThumbnails/prewarm(_:)`` is what redraws them if the reader returns.
        .onDisappear { AvatarKitThumbnails.removeAll() }
    }

    // MARK: - The layer board

    /// The eight layers, all of them, in two fixed rows.
    ///
    /// # Why a board and not the scrolling rail it was
    ///
    /// Eight chips are about six hundred points of text and a phone is four hundred wide, so a
    /// single row could only ever be a scroller — and a scroller of *categories* is the worst
    /// kind, because a reader cannot know what they have not seen. Two rows fit all eight in
    /// three hundred and fifty, which turns "what else is there" from a swipe into a glance. It
    /// costs one row of the option grid below, and buys the only thing on this screen that
    /// never moves.
    ///
    /// Chip shape and treatment are ``ActivityFilterRail``'s and for its reasons: tinted glass
    /// for the selection so the chip still refracts what is behind it, a weight change as well
    /// as a tint so the selection survives a reader who cannot see colour, and 34pt rather than
    /// 44 because these sit directly above the grid they filter.
    private var board: some View {
        LazyVGrid(columns: Self.chipColumns, spacing: 8) {
            ForEach(AvatarKitPart.allCases) { candidate in
                chip(candidate)
            }
        }
        .padding(.horizontal, Self.insets)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a layer")
    }

    private static let chipColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private static let chipHeight: CGFloat = 34

    private func chip(_ candidate: AvatarKitPart) -> some View {
        let isSelected = candidate == part
        return Button {
            part = candidate
        } label: {
            Text(candidate.title)
                .font(.hive(.subheadline, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                // The board is a fixed four across, so a longer word at a larger text size has
                // nowhere to go. Shrinking it keeps the layer readable; wrapping or truncating
                // it would leave a reader choosing between "Extr…" and "Outf…".
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chipHeight)
                .contentShape(.capsule)
        }
        .buttonStyle(.hivePress(.control, in: .capsule))
        .glassEffect(
            isSelected
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .animation(.snappy(duration: 0.22), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Shuffle

    /// The one control this screen is about.
    ///
    /// Full width and prominent, because everything else on the tab is a browse and this is the
    /// decision. The haptic is the soft one the app plays for a reaction — the pattern it
    /// already uses for the thing a reader repeats most, which is exactly what this is.
    private var shuffleButton: some View {
        Button {
            HiveHaptics.play(.reaction)
            avatar = avatar.shuffled()
        } label: {
            Label("Shuffle", systemImage: "shuffle")
                .font(.hive(.body, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.glassProminent)
        .padding(.horizontal, Self.insets)
        .padding(.bottom, 8)
        .accessibilityHint("Builds a new avatar at random")
    }

    // MARK: - Status

    /// What is going on, when something is. Silent otherwise: a line that is always there stops
    /// being read, and this one has to be read the once it says a save failed.
    @ViewBuilder
    private var status: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.hive(.footnote))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Self.insets)
        } else if isPreparing {
            Text("Saving your avatar…")
                .font(.hive(.footnote))
                .foregroundStyle(.secondary)
        }
    }
}
