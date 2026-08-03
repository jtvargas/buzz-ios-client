import SwiftUI

/// The middle step of the join: the face and the name this community will know you by.
///
/// # Why this exists at all
///
/// It was a name field stacked above the key picker, and it was the field people skipped. That
/// is the expensive one to skip: a fresh identity has no profile, so the first thing a community
/// sees of a new member who skipped it is a 63-character `npub` and a generated monogram, for
/// ever, or until they find the account screen. Given a screen with a face on it, the answer
/// gets given — which is the whole reason Buzz's other clients ask here too.
///
/// # Why emoji and not a photo
///
/// The account screen's editor (``ProfileAvatarEditorView``) offers both. It can, because by
/// then there is a community, a committed key and an engine to upload a photo through. Here
/// there is none of that — the key is not created until the last step and the relay has not
/// admitted it — so a photo would have to be held somewhere and uploaded after the join, which
/// is a second failure path on a screen whose entire content is optional. An emoji avatar is a
/// `data:` URI (§ ``EmojiAvatar``) needing nothing but a glyph and a colour, which is exactly
/// why Buzz stores the workspace owner's avatar as one. The photo route stays one tap away on
/// the account screen, which is where the note under the card points.
struct JoinCommunityProfileStep: View {
    @Binding var displayName: String
    @Binding var emoji: String?
    @Binding var color: String
    @FocusState.Binding var focused: JoinField?

    /// Whether the full emoji grid is up.
    @State private var isPickingEmoji = false

    var body: some View {
        VStack(spacing: 14) {
            avatar
            nameCard
            if emoji != nil {
                colorCard
            }
        }
        // Scoped to the two things that change the *shape* of this step. Animating on every
        // change would put a movement under each keystroke in the name field.
        .animation(.snappy(duration: 0.25), value: emoji == nil)
        .sheet(isPresented: $isPickingEmoji) {
            NavigationStack {
                EmojiPickerView { picked in
                    emoji = picked
                    isPickingEmoji = false
                }
                .navigationTitle("Your picture")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isPickingEmoji = false }
                    }
                }
            }
        }
    }

    // MARK: - The face

    private static let avatarSize: CGFloat = 108

    /// The picture, at the size the step is about it — with the quick glyphs under it.
    ///
    /// Tapping the circle opens the full grid. The row beneath is not a shortcut *to* that
    /// grid: it is the answer for the reader who does not care which emoji it is and wants to
    /// be past this screen, which is most of them. Seven glyphs is what fits one row at the
    /// text sizes people use without becoming a second grid.
    private var avatar: some View {
        VStack(spacing: 14) {
            Button {
                focused = nil
                isPickingEmoji = true
            } label: {
                preview
            }
            .buttonStyle(.hivePress(.control, in: .circle))
            .accessibilityLabel(previewLabel)
            .accessibilityHint("Opens the full emoji picker")

            quickRow
        }
    }

    private var preview: some View {
        ZStack {
            Circle()
                .fill(Color(avatarHex: color) ?? .white)
                .opacity(emoji == nil ? 0.12 : 1)

            if let emoji {
                // 50% of the circle, which is where `font-size="258"` in the 512-unit document
                // puts the glyph — so the preview lands where the stored avatar will draw it
                // rather than merely near it.
                Text(emoji)
                    .font(.hive(fixedSize: Self.avatarSize * 0.5, relativeTo: .largeTitle))
                    .minimumScaleFactor(0.5)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "face.smiling")
                        .font(.hive(.title, weight: .regular))
                    Text("Pick one")
                        .font(.hive(.caption2, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        // The palette runs to white and to black, either of which vanishes into this
        // background. A hairline is what keeps the circle a circle at both ends of it.
        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .contentShape(.circle)
    }

    private var previewLabel: String {
        guard let emoji else { return "No picture picked" }
        return "\(EmojiCatalog.unicodeName(of: emoji)) on \(color)"
    }

    /// Glyphs that read as a person rather than as an object, so the row is a set of faces to
    /// choose between instead of a sample of the catalogue.
    private static let quickEmoji = ["🐝", "🙂", "😎", "🦊", "🚀", "🌿", "⭐️"]

    private var quickRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.quickEmoji, id: \.self) { glyph in
                Button {
                    HiveHaptics.play(.reaction)
                    emoji = glyph
                } label: {
                    Text(glyph)
                        .font(.hive(fixedSize: 24, relativeTo: .body))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                        .background {
                            if emoji == glyph {
                                Circle().fill(.white.opacity(0.14))
                            }
                        }
                }
                .buttonStyle(.hivePress(.control, in: .circle))
                .accessibilityLabel(EmojiCatalog.unicodeName(of: glyph))
                .accessibilityAddTraits(emoji == glyph ? [.isSelected] : [])
            }
        }
    }

    // MARK: - The name

    private var nameCard: some View {
        JoinCard {
            JoinCardLabel(text: "YOUR NAME HERE", systemImage: "person")
            TextField("", text: $displayName, prompt: namePrompt)
                .textContentType(.nickname)
                .focused($focused, equals: .name)
                .submitLabel(.done)
                .joinFieldBackground()
            JoinCardNote(text: JoinCommunityModel.displayNameBlurb)
        }
    }

    /// Dimmed rather than left to the platform's placeholder grey, which on glass over a dark
    /// lattice is very nearly the same value as the field's own fill.
    private var namePrompt: Text {
        Text("Your name").foregroundStyle(.white.opacity(0.35))
    }

    // MARK: - The colour

    /// The background palette, scrolling sideways.
    ///
    /// Only once a glyph is chosen. A colour row above an empty circle is a control for a
    /// decision the reader has not started making, and on a screen this short it reads as a
    /// second required question.
    private var colorCard: some View {
        JoinCard {
            JoinCardLabel(text: "BACKGROUND", systemImage: "paintpalette")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(EmojiAvatar.palette, id: \.self, content: swatch)
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func swatch(_ hex: String) -> some View {
        let isSelected = hex.caseInsensitiveCompare(color) == .orderedSame
        return Button {
            HiveHaptics.play(.reaction)
            color = hex
        } label: {
            Circle()
                .fill(Color(avatarHex: hex) ?? .clear)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                // Drawn outside the swatch rather than inside it, so the colour is never partly
                // covered by the mark that says it is chosen — which on the pale end of this
                // palette is the only way to tell two of them apart.
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.hiveAccent, lineWidth: 2)
                    }
                }
                // The target is the platform minimum even though the swatch is 30pt.
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .accessibilityLabel(hex)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
