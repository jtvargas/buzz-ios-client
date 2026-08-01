import BuzzKit
import SwiftUI
import UIKit

/// The account hub: edit your profile, copy your `npub`, back up your secret key,
/// and sign out. Presented as a sheet from the channel list.
struct AccountView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: ProfileModel?
    @State private var showSignOutConfirm = false
    @State private var copiedNpub = false

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
            Form {
                if let model {
                    profileSection(model)
                    keySection(model)
                }
                signOutSection
            }
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

    // MARK: - Profile

    @ViewBuilder
    private func profileSection(_ model: ProfileModel) -> some View {
        @Bindable var model = model
        Section("Profile") {
            TextField("Display name", text: $model.draftDisplayName)
                .textInputAutocapitalization(.words)
            TextField("About", text: $model.draftAbout, axis: .vertical)
                .lineLimit(1 ... 4)
            Button {
                Task { await model.save() }
            } label: {
                if model.isSaving {
                    ProgressView()
                } else {
                    Text(model.didSave ? "Saved" : "Save Profile")
                }
            }
            .disabled(model.isSaving || !model.hasLoaded)
            if let saveError = model.saveError {
                Text(saveError).font(.hive(.footnote)).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Key

    @ViewBuilder
    private func keySection(_ model: ProfileModel) -> some View {
        Section("Your key") {
            Button {
                UIPasteboard.general.string = model.npub
                copiedNpub = true
            } label: {
                LabeledContent {
                    Image(systemName: copiedNpub ? "checkmark" : "doc.on.doc")
                } label: {
                    Text(model.npub)
                        .font(.hiveMono(.footnote))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityLabel("Copy your npub")

            if let selfPubkey {
                NavigationLink("Back Up Secret Key") {
                    KeyBackupView(selfPubkey: selfPubkey)
                }
            }
        }
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

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showSignOutConfirm = true
            }
            .frame(maxWidth: .infinity)
            // Not while the session is still coming up. The workspace now mounts before the
            // engine has started (so a slow relay never blocks the app), which put this
            // button on screen during a launch for the first time — and a teardown that
            // lands mid-start races a setup that cannot be cancelled. See
            // ``AppEnvironment/signOut()``. There is also nothing to leave yet.
            .disabled(environment.isStartingEngine)
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
}
