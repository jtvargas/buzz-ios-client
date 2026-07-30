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
    @State private var signOutFailed = false
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
                "Sign out of Hive?",
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        // Only leave once the key is confirmed removed; a failed
                        // delete keeps us here and surfaces the error.
                        if await environment.signOut() == .signedOut {
                            dismiss()
                        } else {
                            signOutFailed = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "You'll need your key or a fresh pairing to sign back in. Your messages stay on this "
                        + "device unless a different identity signs in."
                )
            }

            if signOutFailed {
                Text("Couldn't remove your key from this device. You're still signed in — please try again.")
                    .font(.hive(.footnote))
                    .foregroundStyle(.red)
            }
        }
    }
}
