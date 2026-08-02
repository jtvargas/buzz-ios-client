import SwiftUI

/// The "paste an existing `nsec`" onboarding path. The key is held only in the
/// field until submit, committed to the Keychain, and never retained afterwards.
struct PasteKeyView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Prefilled from the hub's relay field; editable here.
    @State private var relayURLString: String
    @State private var nsec = ""
    @State private var error: IdentityGateError?
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    init(relayURLString: String) {
        _relayURLString = State(initialValue: relayURLString)
    }

    private enum Field: Hashable {
        case relay
        case secret
    }

    private var canSubmit: Bool {
        !isSubmitting && !nsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Relay") {
                TextField("wss://relay.example", text: $relayURLString)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .relay)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .secret }
            }

            Section {
                SecureField("nsec1…", text: $nsec)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .secret)
                    .submitLabel(.go)
                    .onSubmit(submit)
            } header: {
                Text("Secret key")
            } footer: {
                Text("Your nsec is stored only in this device's Keychain and never leaves it.")
            }

            if let error {
                Section {
                    Text(error.message)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error.message)")
                }
            }
        }
        .navigationTitle("Paste Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect", action: submit).disabled(!canSubmit)
            }
        }
        .overlay {
            if isSubmitting { ProgressView().controlSize(.large) }
        }
        .animation(.default, value: error)
        .disabled(isSubmitting)
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        isSubmitting = true
        error = nil
        let relay = relayURLString
        let secret = nsec
        Task {
            let result = await environment.submitIdentity(relayURLString: relay, nsec: secret)
            isSubmitting = false
            error = result
            if result == nil { nsec = "" }
        }
    }
}
