import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Key backup: shows the public `npub` freely, and reveals the secret `nsec` only
/// behind a device-authentication prompt. Copying the secret carries an explicit
/// warning, and the reveal can be hidden again.
struct KeyBackupView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: KeyBackupModel?
    @State private var copiedNpub = false
    @State private var copiedNsec = false

    private let selfPubkey: String

    init(selfPubkey: String) {
        self.selfPubkey = selfPubkey
    }

    var body: some View {
        Form {
            if let model {
                publicSection(model)
                secretSection(model)
            }
        }
        .navigationTitle("Back Up Key")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = KeyBackupModel(
                    selfPubkey: selfPubkey,
                    authenticator: BiometricAuth(),
                    loadKey: { environment.revealSecretKey() }
                )
            }
        }
    }

    // MARK: - Public key

    private func publicSection(_ model: KeyBackupModel) -> some View {
        Section {
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
        } header: {
            Text("Public key (npub)")
        } footer: {
            Text("Safe to share — this is your public identity.")
        }
    }

    // MARK: - Secret key

    @ViewBuilder
    private func secretSection(_ model: KeyBackupModel) -> some View {
        Section {
            if let nsec = model.revealedNsec {
                Text(nsec)
                    .font(.hiveMono(.footnote))
                    .textSelection(.enabled)
                Button {
                    setPasteboardWithExpiry(nsec)
                    copiedNsec = true
                } label: {
                    Label(
                        copiedNsec ? "Copied — paste it somewhere safe now" : "Copy Secret Key",
                        systemImage: "doc.on.doc"
                    )
                }
                Button("Hide") { model.hideSecret(); copiedNsec = false }
            } else {
                Button {
                    Task { await model.revealSecret() }
                } label: {
                    if model.isAuthenticating {
                        ProgressView()
                    } else {
                        Label("Reveal Secret Key", systemImage: "faceid")
                    }
                }
                .disabled(model.isAuthenticating)
                if model.revealFailed {
                    Text("Couldn't verify it's you. The secret key stays hidden.")
                        .font(.hive(.footnote))
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Secret key (nsec)")
        } footer: {
            Text(
                "Anyone with this key controls your identity. Never share it, and store it only in a "
                    + "password manager."
            )
        }
        .animation(.default, value: model.isRevealed)
    }

    /// Copies the secret to the pasteboard with a short expiry so it does not linger
    /// there indefinitely.
    private func setPasteboardWithExpiry(_ secret: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [.expirationDate: Date().addingTimeInterval(60)]
        )
    }
}
