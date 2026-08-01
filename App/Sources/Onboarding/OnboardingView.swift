import SwiftUI

/// The launch onboarding hub — three clean paths onto Hive: create a brand-new
/// identity, scan a pairing QR from the desktop, or paste an existing `nsec`. The
/// relay field is shared by Create and Paste; the Scan path takes its relay from
/// the QR instead.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Whether this is a reader joining *another* community rather than arriving on Hive.
    ///
    /// The same three paths either way, which is the point — a community is a relay and an
    /// identity, and there is no third way to come by one. Flutter reuses its pairing page
    /// the same way (`PairingPage(addingCommunity: true)`). What changes is the framing: the
    /// welcome becomes a title that says what will happen, and there is a way out.
    let isAddingCommunity: Bool

    @State private var relayURLString: String
    @State private var error: IdentityGateError?
    @State private var isBusy = false
    @FocusState private var relayFocused: Bool

    /// - Parameter isAddingCommunity: see the property. The relay field starts empty in that
    ///   mode: the stored URL is the community already open, and prefilling it would offer
    ///   to "add" the one the reader is standing in.
    init(isAddingCommunity: Bool = false) {
        self.isAddingCommunity = isAddingCommunity
        _relayURLString = State(initialValue: isAddingCommunity ? "" : RelayEndpoint.storedURLString)
    }

    /// Whether this gate is standing in front of a phone that has other communities on it.
    /// One community and no way back is not a dead end — it is a fresh install.
    private var hasSomewhereElseToBe: Bool {
        environment.communities.communities.count > 1
    }

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
                            .font(.hive(.footnote))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Error: \(error.message)")
                    }
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(isAddingCommunity ? "Add community" : "Welcome to Hive")
            .navigationBarTitleDisplayMode(isAddingCommunity ? .inline : .large)
            .toolbar {
                if isAddingCommunity {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                } else if hasSomewhereElseToBe {
                    // The way out of a dead end. Switching to a community this phone has
                    // been signed out of lands here — the gate is how you sign back into it
                    // — and without this the only other community on the device would be
                    // unreachable, because the switcher lives on a home screen that is not
                    // being drawn.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Communities") { environment.communitySheet = .switcher }
                    }
                }
            }
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
                .font(.hiveSymbol(fixedSize: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(isAddingCommunity ? Self.addingBlurb : Self.welcomeBlurb)
                .font(.hive(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RELAY")
                .font(.hive(.caption2, weight: .semibold))
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
                .font(.hive(.caption2))
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

extension OnboardingView {
    static let welcomeBlurb = "Connect your identity to start messaging on the Buzz relay."
    /// Says the one thing a reader adding their second community needs to know, which is
    /// that it does not cost them the first.
    static let addingBlurb =
        "A community is a relay. Point Hive at another one to join it — the communities "
            + "you're already in stay where they are."
}

/// The pushable onboarding sub-flows.
enum OnboardingRoute: Hashable {
    case paste
    case scan
}
