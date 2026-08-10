import BuzzKit
import PhotosUI
import SwiftUI

/// Picks an avatar: a photo from the library, an emoji on a colour, or one built out of
/// layered artwork.
///
/// # Why the emoji is drawn twice
///
/// The preview here is a `Circle` and a `Text`, not the SVG the avatar is *stored* as. The
/// document goes to the relay and comes back rendered by ``SVGAvatarRenderer`` for every
/// other surface in the app; re-encoding and re-rasterising it on each tap to show it in
/// the one place the ingredients are already in hand would put a raster between a finger
/// and its own feedback. The two agree because the document is one rect and one centred
/// glyph — which is the same reason that renderer can be a subset parser at all.
///
/// # Why there is no Animated tab
///
/// Desktop has three. The third is out of scope by instruction, and a tab that exists to
/// say "not yet" is worse than one that is not there.
struct ProfileAvatarEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model: ProfileAvatarEditorModel
    @State private var pickedPhotos: [PhotosPickerItem] = []

    /// The initials to show while there is no artwork, so the empty state is the same face
    /// the rest of the app draws for this person rather than a generic silhouette.
    private let monogram: String
    /// The monogram's stable colour seed — the pubkey.
    private let seed: String
    /// Hands back the new `picture` value. Called only from Done.
    private let onSave: (String) -> Void

    init(
        picture: String?,
        uploader: (any MediaUploading)?,
        monogram: String,
        seed: String,
        onSave: @escaping (String) -> Void
    ) {
        _model = State(wrappedValue: ProfileAvatarEditorModel(picture: picture, uploader: uploader))
        self.monogram = monogram
        self.seed = seed
        self.onSave = onSave
    }

    /// The preview's diameter — larger than any avatar the app draws in place, because the
    /// whole screen is about this one picture.
    private static let previewSize: CGFloat = 132

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 20) {
                tabs($model.tab)
                preview
                Group {
                    switch model.tab {
                    case .image: imageTab
                    case .emoji: emojiTab
                    case .avatarKit: avatarKitTab($model.avatarKitAvatar)
                    }
                }
            }
            .padding(.top, 12)
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) { doneButton }
            }
        }
        // The build tab's tiles are worth tens of megabytes and are worth nothing to any
        // other screen — everywhere else draws a *finished* avatar, never a part. Handing
        // them back is why that cache is an `NSCache` and not a dictionary, and nothing
        // called it; ``AvatarKitThumbnails/prewarm(_:)`` redraws them if the reader returns.
        //
        // Said here, on the sheet, and deliberately *not* on ``AvatarKitEditorView``: that
        // view is one arm of the tab switch above, so it leaves the hierarchy every time the
        // reader looks at the photo or emoji tab. Releasing there would throw away the tiles
        // of the grid they are still using and redraw them on the way back — the opposite of
        // what this cache is for.
        .onDisappear { AvatarKitThumbnails.removeAll() }
    }

    // MARK: - Tabs

    private func tabs(_ selection: Binding<ProfileAvatarEditorModel.Tab>) -> some View {
        Picker("Avatar kind", selection: selection) {
            ForEach(ProfileAvatarEditorModel.Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        Group {
            switch model.tab {
            case .emoji:
                emojiPreview
            case .image:
                imagePreview
            case .avatarKit:
                avatarKitPreview
            }
        }
        .frame(width: Self.previewSize, height: Self.previewSize)
        .accessibilityElement()
        .accessibilityLabel(previewLabel)
    }

    private var emojiPreview: some View {
        Circle()
            .fill(Color(avatarHex: model.color) ?? .white)
            .overlay {
                if let emoji = model.emoji {
                    // 56% of the circle, which is what `font-size="258"` in a 512-unit
                    // document comes to — so the glyph lands where the stored avatar will
                    // draw it rather than merely near it.
                    Text(emoji)
                        .font(.hive(fixedSize: Self.previewSize * 0.5, relativeTo: .largeTitle))
                        .minimumScaleFactor(0.5)
                } else {
                    Text("Pick an emoji")
                        .font(.hive(.footnote))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .multilineTextAlignment(.center)
                }
            }
            // The palette runs to white and to black, either of which vanishes into a
            // sheet's own background. A hairline is what keeps the circle a circle at both
            // ends of it.
            .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let picked = model.imagePreview {
            Image(uiImage: picked)
                .resizable()
                .scaledToFill()
                .clipShape(.circle)
                .overlay { if model.isUploading { uploadingVeil } }
        } else if let url = model.imageURL.flatMap(URL.init(string:)) {
            AvatarView(
                url: url,
                seed: seed,
                monogram: monogram,
                size: Self.previewSize,
                shape: .circle
            )
        } else {
            AvatarView(
                url: nil,
                seed: seed,
                monogram: monogram,
                size: Self.previewSize,
                shape: .circle
            )
        }
    }

    /// Over the photo rather than beside it: the picture is already on screen, and what is
    /// unfinished about it is that it is not on the relay yet.
    private var uploadingVeil: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35))
            ProgressView().tint(.white)
        }
    }

    private var previewLabel: String {
        switch model.tab {
        case .emoji:
            model.emoji.map { "\(EmojiCatalog.unicodeName(of: $0)) on \(model.color)" }
                ?? "No emoji picked"
        case .image:
            model.imageURL == nil ? "No photo picked" : "Your photo"
        case .avatarKit:
            "The avatar you're building"
        }
    }

    // MARK: - Image

    private var imageTab: some View {
        VStack(spacing: 12) {
            PhotosPicker(
                selection: $pickedPhotos,
                maxSelectionCount: 1,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label(
                    model.imageURL == nil ? "Choose Photo" : "Choose a Different Photo",
                    systemImage: "photo.on.rectangle"
                )
                .font(.hive(.body, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(model.isUploading)

            if model.isUploading {
                Text("Uploading…")
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
            }

            if let uploadError = model.uploadError {
                Text(uploadError)
                    .font(.hive(.footnote))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if model.imageURL != nil, !model.isUploading {
                Button("Remove Photo", role: .destructive) { model.removeImage() }
                    .font(.hive(.footnote))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        // Empties the picker's own selection so choosing the same photo twice is two
        // picks — the composer's rule, for the same reason.
        .onChange(of: pickedPhotos) { _, items in
            guard let item = items.first else { return }
            pickedPhotos = []
            Task { await model.upload(item) }
        }
    }

    // MARK: - Emoji

    private var emojiTab: some View {
        VStack(spacing: 12) {
            colorRow
            // Reused whole rather than reimplemented: it already has the catalogue, the
            // search, the pinned headings and the 44pt targets, and an avatar picker that
            // drifted from the reaction picker would be two grids of the same glyphs
            // behaving differently.
            EmojiPickerView(searchPlacement: .bottomBar) { model.select(emoji: $0) }
        }
    }

    /// The palette, scrolling sideways.
    ///
    /// Desktop draws these as a three-row block under the grid. On a phone that block and
    /// the grid cannot both be on screen at a text size anyone actually uses, and the one
    /// that goes below the fold is whichever the reader needs next. A single row above the
    /// grid keeps both controls reachable without scrolling to either.
    private var colorRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(EmojiAvatar.palette, id: \.self, content: swatch)
                customColorWell
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private static let swatchSize: CGFloat = 32

    private func swatch(_ hex: String) -> some View {
        let isSelected = hex.caseInsensitiveCompare(model.color) == .orderedSame
        return Button {
            HiveHaptics.play(.reaction)
            model.select(color: hex)
        } label: {
            Circle()
                .fill(Color(avatarHex: hex) ?? .clear)
                .frame(width: Self.swatchSize, height: Self.swatchSize)
                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                // Drawn outside the swatch rather than inside it, so the colour is never
                // partly covered by the mark that says it is chosen — which on the pale
                // end of this palette is the only way to tell two of them apart.
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                // The target is the platform minimum even though the swatch is 32pt.
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .accessibilityLabel(hex)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The colour well, for a background the palette does not hold. Desktop's custom
    /// swatch opens a hue grid; the platform already ships that picker, so this is it.
    private var customColorWell: some View {
        ColorPicker(
            "Custom colour",
            selection: Binding(
                get: { Color(avatarHex: model.color) ?? .white },
                set: { model.select(color: $0.avatarHex) }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .frame(width: 44, height: 44)
    }

    // MARK: - Done

    /// The confirm action, in the navigation bar opposite Cancel.
    ///
    /// It was a full-width bar across the bottom, which is the shape a one-decision screen
    /// usually wants — but this screen's decision is made *in a grid*, and a 50pt button
    /// plus its margins took that grid's last two rows. In the bar it costs nothing, and it
    /// sits where the Cancel it undoes already was.
    ///
    /// # Why one of the three tabs makes it wait
    ///
    /// A photo and an emoji both have their picture ready by the time Done can be pressed —
    /// one was uploaded on the pick, the other is a string. A built avatar has nothing until
    /// something draws it, and drawing it on every press of Shuffle is not an option. So on
    /// that tab alone Done is the thing that draws and uploads, and it spins while it does.
    /// The other two keep the path they had, synchronously and unchanged.
    private var doneButton: some View {
        Button {
            // `canSave` gates the button, so on the picking tabs the value is there; the
            // guard is what keeps that a fact rather than an assumption.
            if let picture = model.pictureValue {
                onSave(picture)
                dismiss()
                return
            }
            Task {
                guard let picture = await model.publishAvatarKit() else { return }
                onSave(picture)
                dismiss()
            }
        } label: {
            if model.isPreparingAvatarKit {
                ProgressView()
            } else {
                Text("Done")
            }
        }
        .disabled(!model.canSave)
        // Named rather than read off the label, which for the seconds it is a spinner has
        // nothing to read.
        .accessibilityLabel("Done")
    }
}

// MARK: - AvatarKit

/// The third tab's two pieces, in an extension rather than in the body above, so the type
/// that had two tabs still reads as a type with two tabs and a third arriving through three
/// `case` arms.
private extension ProfileAvatarEditorView {
    /// The built avatar at the preview's size, drawn by the very view the export will draw —
    /// which is what makes "what I saw" and "what got uploaded" the same picture.
    var avatarKitPreview: some View {
        AvatarKitAvatarPreview(avatar: model.avatarKitAvatar, side: Self.previewSize)
    }

    /// The build tab.
    ///
    /// Handed the one value it changes rather than the whole model, so a picker cannot reach
    /// the photo upload it has no business touching — and so it opens on its own.
    func avatarKitTab(_ avatar: Binding<AvatarKitAvatar>) -> some View {
        AvatarKitEditorView(
            avatar: avatar,
            isPreparing: model.isPreparingAvatarKit,
            errorMessage: model.avatarKitError
        )
    }
}
