import SwiftUI

/// The launch onboarding hub — three clean paths onto Hive: create a brand-new
/// identity, scan a pairing QR from the desktop, or paste an existing `nsec`. The
/// relay field is shared by Create and Paste; the Scan path takes its relay from
/// the QR instead.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var relayURLString = RelayEndpoint.storedURLString
    @State private var error: IdentityGateError?
    @State private var isBusy = false
    @FocusState private var relayFocused: Bool

    private var relayIsValid: Bool {
        RelayEndpoint.websocketURL(from: relayURLString) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    relaySection
                    actions
                    if let error {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Error: \(error.message)")
                    }
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Welcome to Hive")
            .navigationDestination(for: OnboardingRoute.self, destination: destination)
            .overlay {
                if isBusy { ProgressView().controlSize(.large) }
            }
            .animation(.default, value: error)
            .disabled(isBusy)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Connect your identity to start messaging on the Buzz relay.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RELAY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("ws://host:port", text: $relayURLString)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($relayFocused)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            Text("Used when creating a new identity or pasting a key. Scanning a QR uses the relay from your desktop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: create) {
                Label("Create New Identity", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(!relayIsValid)

            NavigationLink(value: OnboardingRoute.scan) {
                Label("Scan QR from Desktop", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            NavigationLink(value: OnboardingRoute.paste) {
                Label("Paste Existing Key", systemImage: "key.horizontal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func destination(_ route: OnboardingRoute) -> some View {
        switch route {
        case .paste:
            PasteKeyView(relayURLString: relayURLString)
        case .scan:
            PairingFlowView()
        }
    }

    // MARK: - Actions

    private func create() {
        guard !isBusy, relayIsValid else {
            error = .invalidRelayURL
            return
        }
        relayFocused = false
        isBusy = true
        error = nil
        let relay = relayURLString
        Task {
            let result = await environment.createIdentity(relayURLString: relay)
            isBusy = false
            error = result
        }
    }
}

/// The pushable onboarding sub-flows.
enum OnboardingRoute: Hashable {
    case paste
    case scan
}
