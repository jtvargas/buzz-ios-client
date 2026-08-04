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
/// # Why a photo is still not one of the three
///
/// The account screen's editor (``ProfileAvatarEditorView``) offers one. It can, because by then
/// there is a community, a committed key and an engine to upload through. Here there is none of
/// that — the key is not created until the last step and the relay has not admitted it — so a
/// photo would have to be held somewhere and uploaded after the join, which is a second failure
/// path on a screen whose entire content is optional. That is still true, and it is still why.
///
/// What changed is that it turned out to be an argument about *bytes*, not about pictures. An
/// emoji avatar is a `data:` URI (§ ``EmojiAvatar``) needing nothing but a glyph and a colour. A
/// built avatar is eight integers (§ ``AvatarKitAvatar``) needing nothing at all until
/// something draws it — and the drawing happens after the join, in
/// ``AppEnvironment/announceArrivalProfile(displayName:picture:)``, at the first moment an
/// engine exists. So it costs this screen exactly what an emoji costs it: nothing. The photo
/// route stays one tap away on the account screen, which is where the note under Shuffle points.
///
/// # Why the built avatar is the default, when nothing was before
///
/// A default *glyph* was refused, and rightly: it would give every member of a community the
/// same face on the day they joined, which is worse than no face at all, because the generated
/// monogram at least differs between people. A rolled avatar is the opposite proposition — the
/// combination runs to tens of millions, so two readers arriving on the same afternoon do not
/// meet the same face, and the one who skips this step entirely still arrives as somebody.
///
/// The step stays as skippable as it was. All three answers are one tap apart, none of them
/// blocks Next, and the reader who wants no picture says so in the same gesture they would have
/// used to leave the circle empty.
///
/// # Why there is only a Shuffle
///
/// Asked for by name. Browsing the layers is what the account screen's editor is for, and it is
/// several minutes of work; a walk that stopped to dress somebody would stop being a walk. One
/// button, and a line underneath saying where the rest of it lives.
struct JoinCommunityProfileStep: View {
    @Binding var displayName: String
    /// Which of the three answers, and the avatar the shuffle has landed on.
    @Binding var picture: ArrivalPictureChoice
    @Binding var emoji: String?
    @Binding var color: String
    @FocusState.Binding var focused: JoinField?

    /// Whether the full emoji grid is up.
    @State private var isPickingEmoji = false

    var body: some View {
        VStack(spacing: 14) {
            face
            kindPicker
            controls
            nameCard
            if picture.kind == .emoji, emoji != nil {
                colorCard
            }
        }
        // Scoped to the two things that change the *shape* of this step. Animating on every
        // change would put a movement under each keystroke in the name field.
        .animation(.snappy(duration: 0.25), value: emoji == nil)
        .animation(.snappy(duration: 0.25), value: picture.kind)
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

    /// The picture, at the size the step is about it.
    ///
    /// Above the picker rather than below it, because it is the answer and the picker is only
    /// how the answer was reached. The eye lands on a face either way; this way it lands on a
    /// face rather than on three words about faces.
    @ViewBuilder
    private var face: some View {
        switch picture.kind {
        case .built:
            // The editor's own preview, not a copy of it: it carries the small pop on change
            // that makes a repeated Shuffle read as the picture answering, and it already
            // handles Reduce Motion. A second implementation of that here is the drift this
            // step and that editor cannot afford.
            AvatarKitAvatarPreview(avatar: picture.avatar, side: Self.avatarSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("A built avatar")
        case .emoji:
            emojiFace
        case .nothing:
            blankFace
        }
    }

    /// The emoji circle, exactly as it was when it was the only one: tapping it opens the full
    /// grid, and the row of quick glyphs is under the picker.
    private var emojiFace: some View {
        Button {
            focused = nil
            isPickingEmoji = true
        } label: {
            preview
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .accessibilityLabel(previewLabel)
        .accessibilityHint("Opens the full emoji picker")
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

    /// What `None` looks like: the empty circle, with nothing to press.
    ///
    /// Drawn rather than left out, so that all three faces are the same height and the picker
    /// under them therefore stays exactly where it is while the reader taps across it. Leaving
    /// it out would slide the segments up under the finger that is choosing between them, which
    /// is how somebody ends up on an answer they did not pick. What is under the picker does
    /// change height between the three, and that is fine — nothing there is being aimed at yet.
    private var blankFace: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            Image(systemName: "person.fill")
                .font(.hive(.title, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No picture")
    }

    // MARK: - Which kind

    /// The three answers, as a segmented control.
    ///
    /// Not inside a ``JoinCard``: the cards on this walk each hold one question with a heading
    /// over it, and this is not a question so much as a way of asking the one above it. On the
    /// glass this reads as a control belonging to the face, which is what it is.
    private var kindPicker: some View {
        Picker("Your picture", selection: $picture.kind) {
            ForEach(ArrivalPictureChoice.Kind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Kind of picture")
    }

    /// The one control the chosen kind offers, if it offers one.
    @ViewBuilder
    private var controls: some View {
        switch picture.kind {
        case .built:
            VStack(spacing: 10) {
                shuffleButton
                JoinCardNote(text: Self.shuffleNote)
                    .multilineTextAlignment(.center)
            }
        case .emoji:
            quickRow
        case .nothing:
            EmptyView()
        }
    }

    /// Where the rest of it is, since this screen deliberately does not have it.
    private static let shuffleNote =
        "Shuffle until one feels like you. The parts can be picked one at a time later, "
            + "from your account."

    /// The only control the built avatar gets.
    ///
    /// Glass rather than the editor's prominent fill, and that is the walk's rule rather than a
    /// preference: the one prominent control on these screens is the button that moves the walk
    /// on, and a filled Shuffle sitting above it would be the loudest thing on a step nobody has
    /// to answer. The haptic is the soft one the app plays for a reaction — the same pattern the
    /// editor's Shuffle plays, so the gesture feels identical in both places.
    private var shuffleButton: some View {
        Button {
            HiveHaptics.play(.reaction)
            picture.avatar = picture.avatar.shuffled()
        } label: {
            Label("Shuffle", systemImage: "shuffle")
                .font(.hive(.subheadline, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityHint("Builds a new avatar at random")
    }

    /// Glyphs that read as a person rather than as an object, so the row is a set of faces to
    /// choose between instead of a sample of the catalogue.
    private static let quickEmoji = ["🐝", "🙂", "😎", "🦊", "🚀", "🌿", "⭐️"]

    /// The row beneath the emoji picker is not a shortcut *to* the full grid: it is the answer
    /// for the reader who does not care which emoji it is and wants to be past this screen.
    /// Seven glyphs is what fits one row at the text sizes people use without becoming a second
    /// grid.
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
    /// Only on the emoji answer, and only once a glyph is chosen. A colour row above an empty
    /// circle is a control for a decision the reader has not started making, and on a screen
    /// this short it reads as a second required question. The built avatar has its own grounds
    /// and rolls one with the rest of it, so this row would be a second, disagreeing answer.
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
