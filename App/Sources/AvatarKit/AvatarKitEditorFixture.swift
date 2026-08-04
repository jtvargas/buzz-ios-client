#if DEBUG
import SwiftUI

/// The avatar builder, opened straight from a launch argument, so its grid can be *looked at*
/// on a simulator instead of only on a phone.
///
/// # Why this exists
///
/// The screen is a picker, and the defects a picker has are the ones a description cannot
/// state: a cell too small to tell two hairstyles apart, a crop that cuts a hat off, a
/// selection ring that disappears into sixteen tiles, four rows that fit or three and a sliver
/// that do not. Every one of those is a second's work to see in a picture and an argument in
/// prose. The editor is otherwise reached through Settings, through the account screen, through
/// a sheet — which on a simulator means standing up an identity and a socket first.
///
/// `-fixtureAvatarKit` opens the whole avatar sheet as the app opens it. `-fixtureAvatarKit
/// hair` opens the same screen with a named layer already chosen, which is the only way to
/// photograph the other seven without a finger. The names are the chips' own: Face, Hair, Eyes,
/// Mouth, Beard, Extras, Outfit, Colour.
///
/// Compiled out of release entirely, like the three fixtures beside it in `App/Sources/App`.
enum AvatarKitEditorFixture {
    enum Mode: Equatable {
        /// The real ``ProfileAvatarEditorView``, seeded so it opens on the build tab.
        case sheet
        /// The build tab alone, under the same chrome, opened on a named layer.
        case layer(AvatarKitPart)
    }

    /// What a launch asked for, or `nil` for an ordinary launch.
    ///
    /// The bare flag is allowed and means the whole sheet — the resting state, and the one
    /// worth looking at most often.
    static func requested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Mode? {
        guard let flag = arguments.firstIndex(of: "-fixtureAvatarKit") else { return nil }
        let next = flag + 1
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("-") else {
            return .sheet
        }
        let name = arguments[next].lowercased()
        let part = AvatarKitPart.allCases.first { $0.title.lowercased() == name }
        // An unknown layer falls back rather than traps: a fixture that crashes on a typo
        // reads as a product failure.
        return part.map(Mode.layer) ?? .sheet
    }

    /// The avatar every fixture launch opens on.
    ///
    /// Fixed rather than shuffled, because the point of these pictures is comparing one run
    /// against the next. It wears an accessory and a beard on purpose: those are the two
    /// layers whose thumbnails are hardest to crop, and a seed that had neither would
    /// photograph the easy case.
    static let seed = AvatarKitAvatar(
        outfit: 4,
        head: 2,
        hair: 6,
        eyes: 2,
        mouth: 3,
        facialHair: 2,
        accessory: 1,
        background: .yellow
    )

    /// The URL the seeded recipe claims to have been published at, so
    /// ``ProfileAvatarEditorModel`` recognises it as this device's own work and opens on the
    /// build tab. Not a real address and never fetched.
    static let seedURL = "hive://fixture/avatarkit.png"

    // MARK: - Measurement

    /// Whether this launch was asked to time the thumbnail draw.
    ///
    /// Its own flag rather than something every fixture launch does, because the measurement
    /// holds the main actor for as long as it takes — which is the one thing that would make
    /// a screenshot taken beside it a picture of a screen mid-draw.
    static func measuring(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("-measureAvatarKitThumbnails")
    }

    /// Times the thumbnail draw and writes the result to standard error.
    ///
    /// The question this answers is the one that decided ``AvatarKitThumbnails``: whether a
    /// grid of composites can be drawn live. Reported rather than asserted — it is a
    /// measurement of the machine it ran on, and a number that varies by device is not a test.
    /// Read it with `xcrun simctl launch --console`, and written to standard error because
    /// standard output is fully buffered when that console is not a terminal, which means a
    /// `print` here arrives only when the app exits.
    @MainActor
    static func measure() {
        let part = AvatarKitPart.hair
        let requests = (0 ..< part.options.count).map { index -> AvatarKitThumbnail in
            var next = seed
            part.apply(index, to: &next)
            return AvatarKitThumbnail(avatar: next, window: part.window)
        }

        let coldStart = CFAbsoluteTimeGetCurrent()
        let drawn = requests.compactMap { AvatarKitThumbnails.drawIgnoringCache($0) }
        let cold = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000

        for request in requests { _ = AvatarKitThumbnails.image(for: request) }
        let warmStart = CFAbsoluteTimeGetCurrent()
        for request in requests { _ = AvatarKitThumbnails.cached(request) }
        let warm = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000

        for (index, image) in drawn.prefix(6).enumerated() {
            guard let data = image.pngData() else { continue }
            let url = URL.documentsDirectory.appending(path: "thumbnail-\(index).png")
            try? data.write(to: url)
        }

        let pixels = drawn.first.map { "\(Int($0.size.width))x\(Int($0.size.height))@\($0.scale)" } ?? "none"
        let line = String(
            format: "AVATARKIT-MEASURE asked=%d drawn=%d size=%@ cold=%.1fms (%.2fms each) "
                + "warm=%.3fms (%.4fms each)\n",
            requests.count, drawn.count, pixels, cold, cold / Double(requests.count),
            warm, warm / Double(requests.count)
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Presents the avatar builder the way the app presents it.
struct AvatarKitEditorFixtureHost: View {
    let mode: AvatarKitEditorFixture.Mode

    /// The build tab's own value, for ``AvatarKitEditorFixture/Mode/layer(_:)`` — which stands
    /// the tab up directly and so has to own what the model would have owned.
    @State private var avatar = AvatarKitEditorFixture.seed

    init(mode: AvatarKitEditorFixture.Mode) {
        self.mode = mode
        // Before any body runs, because ``ProfileAvatarEditorModel`` reads this in its own
        // initialiser and decides which tab to open on from what it finds.
        AvatarKitRecipeStore.save(
            .init(avatar: AvatarKitEditorFixture.seed, publishedURL: AvatarKitEditorFixture.seedURL)
        )
    }

    var body: some View {
        Color.hiveGround
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) { presented }
            .task { if AvatarKitEditorFixture.measuring() { AvatarKitEditorFixture.measure() } }
    }

    @ViewBuilder
    private var presented: some View {
        switch mode {
        case .sheet:
            ProfileAvatarEditorView(
                picture: AvatarKitEditorFixture.seedURL,
                uploader: nil,
                monogram: "JT",
                seed: "fixture"
            ) { _ in }
        case let .layer(part):
            layerChrome(part)
        }
    }

    /// The build tab under the sheet chrome that surrounds it, reproduced.
    ///
    /// A reproduction rather than the real ``ProfileAvatarEditorView`` for one reason: the tab
    /// it wants is chosen by a private model, and the layer within that tab by a private
    /// `@State`, so there is no door to the other seven layers from outside. Every number here
    /// — the top padding, the 20pt stack, the 132pt preview — is copied from that view so the
    /// vertical budget the grid is left with is the real one. The `sheet` mode is the control:
    /// run both and the chrome must match.
    private func layerChrome(_ part: AvatarKitPart) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("Avatar kind", selection: .constant(2)) {
                    Text("Image").tag(0)
                    Text("Emoji").tag(1)
                    Text("AvatarKit").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                AvatarKitAvatarPreview(avatar: avatar, side: 132)
                    .frame(width: 132, height: 132)

                AvatarKitEditorView(
                    avatar: $avatar,
                    isPreparing: false,
                    errorMessage: nil,
                    layer: part
                )
            }
            .padding(.top, 12)
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                ToolbarItem(placement: .confirmationAction) { Button("Done") {} }
            }
        }
    }
}
#endif
