import BuzzKit
import SwiftUI
import UIKit

/// The account hub: change your picture, edit your name and bio, copy your key, back up
/// your secret key, and sign out. Presented as a sheet from the channel list.
///
/// # Why it is cards and not a `Form`
///
/// This was a `Form` with two text fields and a Save button, which made the screen a
/// settings page whose subject was a string. The subject is a *person*: the picture is the
/// largest thing on it, the two facts that describe you sit under it, and the keypair —
/// which is fixed and cannot be edited at all — is a separate card rather than three more
/// rows of the same list. That is the shape Buzz's own profile screen has, so someone who
/// set their avatar on desktop finds the same screen here.
struct AccountView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.entityNames) private var names
    @Environment(\.dismiss) private var dismiss
    /// Read for ``editBadge``'s ring, which has to be the page's own colour. See there.
    @Environment(\.hiveTheme) private var theme

    @State private var model: ProfileModel?
    @State private var isEditingAvatar = false
    @State private var showSignOutConfirm = false

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?

    init(store: BuzzEventStore, engine: SyncEngine, selfPubkey: String?) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let model {
                        avatarHeader(model)
                        AccountProfileInfoCard(model: model)
                        AccountIdentityCard(model: model, selfPubkey: selfPubkey)
                        #if DEBUG
                        AccountExportAvatarCard(picture: model.draftPicture)
                        #endif
                    } else {
                        ProgressView().padding(.top, 60)
                    }
                    signOutButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .hiveSheetGround()
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if model == nil, let selfPubkey {
                    let model = ProfileModel(store: store, selfPubkey: selfPubkey, sender: engine)
                    self.model = model
                    await model.run()
                }
            }
        }
    }

    // MARK: - Avatar

    /// The header avatar's point size. Larger than ``ProfileSheetView/avatarSize`` because
    /// this screen is where the picture is *changed*, so it is the subject rather than an
    /// illustration of one.
    private static let avatarSize: CGFloat = 112

    private func avatarHeader(_ model: ProfileModel) -> some View {
        VStack(spacing: 10) {
            Button {
                isEditingAvatar = true
            } label: {
                AvatarView(
                    // The draft rather than the resolved name table, so the new picture is
                    // on screen the moment Done is tapped instead of when the relay echoes
                    // the metadata back.
                    url: model.draftPicture.flatMap(URL.init(string:)),
                    seed: model.pubkeyHex,
                    monogram: names.initials(for: model.pubkeyHex),
                    size: Self.avatarSize,
                    shape: .circle
                )
                // The badge sits on the circle's edge rather than beside it, so the control
                // that changes the picture is visibly part of the picture — which is what
                // makes a tap on the face itself the obvious move.
                .overlay(alignment: .bottomTrailing) { editBadge }
            }
            .buttonStyle(.hivePress(.control, in: .circle))
            .accessibilityLabel("Change your picture")

            Text("Update how your name, picture, and bio appear across Buzz.")
                .font(.hive(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $isEditingAvatar) {
            ProfileAvatarEditorView(
                picture: model.draftPicture,
                uploader: environment.mediaUploader,
                monogram: names.initials(for: model.pubkeyHex),
                seed: model.pubkeyHex
            ) { picture in
                Task { await model.updateAvatar(picture) }
            }
        }
    }

    private var editBadge: some View {
        Image(systemName: "pencil")
            .font(.hiveSymbol(.footnote, weight: .semibold))
            .foregroundStyle(Color(.systemBackground))
            .frame(width: 34, height: 34)
            .background(Circle().fill(.tint))
            // A ring in the page's own colour, so the badge reads as sitting on top of the
            // avatar rather than punched out of it — the same treatment the connection dot
            // gets in ``AccountAvatarButton``.
            //
            // Which means it follows ``View/hiveSheetGround()`` and is dynamic with it — the
            // same ``HiveTheme/elevatedBackground`` that modifier paints, now that the page is
            // the reader's theme rather than `systemGroupedBackground`. Any fixed colour here
            // is a ring in the wrong dark on fourteen of the fifteen themes: #124 moved the
            // ground and this together, and every later move has to move both.
            .overlay(Circle().strokeBorder(theme.elevatedBackground, lineWidth: 3))
            .accessibilityHidden(true)
    }

    // MARK: - Sign out

    /// Named for what it actually does. Signing out removes the key for *every* community
    /// on this phone — each one signs with its own (§ ``Community/keychainAccount``) — and a
    /// dialog saying "Hive" while a reader is standing in one of three communities reads as
    /// an offer to leave only that one.
    private var signOutTitle: String {
        environment.communities.communities.count > 1
            ? "Sign out of all \(environment.communities.communities.count) communities?"
            : "Sign out of Hive?"
    }

    private var signOutMessage: String {
        let base = "You'll need your key or a fresh pairing to sign back in. Your messages stay on this "
            + "device unless a different identity signs in."
        guard environment.communities.communities.count > 1 else { return base }
        return "This signs out of every community on this phone. " + base
    }

    private var signOutButton: some View {
        Button("Sign Out", role: .destructive) {
            showSignOutConfirm = true
        }
        .font(.hive(.body, weight: .medium))
        .frame(maxWidth: .infinity, minHeight: 44)
        // Not while the session is still coming up. The workspace now mounts before the
        // engine has started (so a slow relay never blocks the app), which put this
        // button on screen during a launch for the first time — and a teardown that
        // lands mid-start races a setup that cannot be cancelled. See
        // ``AppEnvironment/signOut()``. There is also nothing to leave yet.
        .disabled(environment.isStartingEngine)
        .padding(.top, 4)
        .confirmationDialog(
            signOutTitle,
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                // A refusal is reported by the app rather than here: signing out
                // replaces the workspace this sheet is attached to, so by the time
                // there is anything to say, this view is gone. See
                // ``AppEnvironment/signOut()``.
                Task { await environment.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
    }
}

// MARK: - Exporting a built avatar

#if DEBUG
/// **Debug builds only.** The way to get a built avatar *out* of the app, so a face can be
/// looked at beside the artwork it was assembled from.
///
/// # Why a release does not have it
///
/// What it hands over is a finished, transparent-capable PNG of a face this app can draw
/// again from eight numbers. Shipping that control is offering readers a *template*, which is
/// a different feature with a different set of questions attached to it — this one exists to
/// inspect the builder's own output while it is still a proof of concept. So the whole thing
/// is compiled out, control and plumbing alike, rather than hidden behind a flag that a
/// release still contains.
///
/// # Why it appears for some avatars and not others
///
/// Only for a face this app drew and this device published, which is
/// ``AvatarKitPublishedAvatar/recipe(forPublished:in:)``'s whole subject. A photo and an
/// emoji have no recipe to re-draw, and a build that has since been replaced by one of those
/// is not what is being worn — offering it there would export somebody's *previous* avatar.
private struct AccountExportAvatarCard: View {
    /// What the profile is publishing right now. The same value the header above draws from,
    /// so this row cannot end up disagreeing with the face it is talking about.
    let picture: String?

    /// The prepared file, whose presence is the entire arming condition — there is no separate
    /// "should this show" flag, because a picture with no recipe behind it produces no file.
    ///
    /// Prepared ahead of the tap rather than during it, because `ShareLink` has to be handed
    /// its item when it is built rather than when it is pressed.
    @State private var export: AvatarKitPublishedAvatar.Export?

    var body: some View {
        content
            // Keyed by the picture, so switching to a photo takes the row away and building a
            // new face replaces the file instead of sharing the one before it.
            .task(id: picture) {
                export = AvatarKitPublishedAvatar.recipe(forPublished: picture)
                    .flatMap { try? AvatarKitPublishedAvatar.export($0) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let export {
            AccountCard(
                title: "Debug",
                subtitle: "Only in debug builds. Release doesn't have this."
            ) {
                EmptyView()
            } content: {
                ShareLink(item: export.file, preview: sharePreview(export)) {
                    AccountFieldRow(label: "Built avatar") {
                        HStack(spacing: 10) {
                            Text("Export avatar")
                                .font(.hive(.body))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Image(systemName: "square.and.arrow.up")
                                .font(.hiveSymbol(.footnote, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export your built avatar")
            }
        }
    }

    /// What the share sheet draws while the reader chooses where the picture is going. Always
    /// carries an image — a symbol if the bitmap somehow did not decode — because a preview
    /// without one collapses the sheet's header to a bare filename. ``MessageMediaShareButton``
    /// makes the same allowance for the same reason.
    private func sharePreview(_ export: AvatarKitPublishedAvatar.Export) -> SharePreview<Image, Never> {
        let image = export.image.map { Image(uiImage: $0) } ?? Image(systemName: "person.crop.square")
        return SharePreview("Hive Avatar", image: image)
    }
}
#endif
