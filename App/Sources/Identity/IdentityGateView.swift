import SwiftUI

/// The launch identity gate (minimal by owner decision — real onboarding is a
/// later step). A single Liquid Glass form: the relay URL, prefilled and editable,
/// and a pasted `nsec`. On submit the key is committed to the Keychain and the
/// engine starts. The key is held only in the field until submit and never leaves
/// the Keychain afterwards.
struct IdentityGateView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var relayURLString = RelayEndpoint.storedURLString
    @State private var nsec = ""
    @State private var error: IdentityGateError?
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case relay
        case secret
    }

    private var canSubmit: Bool {
        !isSubmitting && !nsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("ws://host:port", text: $relayURLString)
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
                        .onSubmit { submit() }
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
            .navigationTitle("Connect to Hive")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: submit)
                        .disabled(!canSubmit)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView().controlSize(.large)
                }
            }
            .animation(.default, value: error)
        }
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
