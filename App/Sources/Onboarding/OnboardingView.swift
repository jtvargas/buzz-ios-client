import BuzzKit
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
    @State private var lookup = CommunityLookup()
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

    /// What is in the relay field, read once (§ ``CommunityAddress``).
    ///
    /// Both relay forms are taken, because both are forms people have a relay written down
    /// in: the socket URL an operator quotes (`wss://relay.example`) and the web address the
    /// same relay serves its own pages on (`https://relay.example`) — the one you get by
    /// copying the address bar. And an **invite link** is recognised rather than refused,
    /// because pasting one here is the commonest thing anybody does with this field: it is
    /// the only address most people are ever given.
    private var address: CommunityAddress {
        CommunityAddress(relayURLString)
    }

    /// The invitation in the field, if that is what this is. Its presence changes what the
    /// screen is for: an invite is not an identity decision, it is a different route entirely.
    private var invitation: InviteLink? {
        if case let .invitation(link) = address { return link }
        return nil
    }

    /// Whether the two identity buttons can act. An invite in the field disables them on
    /// purpose: `Create New Identity` against a relay you have an invite to would mint a
    /// stranger and connect it to a relay that has never heard of it — which is the empty
    /// sidebar this whole screen keeps producing.
    private var relayIsValid: Bool {
        if case .relay = address { return true }
        return false
    }

    /// The note under the field. Every state of the field says something, including the ones
    /// that are nobody's mistake.
    private var relayNote: String {
        switch address {
        case .nothingYet: Self.relayNote
        case .relay: Self.relayNote
        case .invitation: Self.inviteNote
        case .unusable(.hasAPageUnderIt): Self.relayHasAPageNote
        case .unusable(.notAnAddress): Self.relayRefusedNote
        }
    }

    /// Whether the note is a refusal, so it can be drawn as one.
    private var relayIsRefused: Bool {
        if case .unusable = address { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    if address.relayURLString != nil {
                        CommunityCard(
                            name: lookup.name,
                            icon: lookup.icon,
                            isChecking: lookup.isChecking,
                            isVerified: lookup.isVerified
                        )
                    }
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
            // Driven from the *reduced* relay rather than from the text, so a card resolves
            // once per host and not once per keystroke inside an invite code.
            .onChange(of: address.relayURLString, initial: true) { _, relay in
                lookup.look(at: relay)
            }
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
            TextField("wss://relay.example", text: $relayURLString)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($relayFocused)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            // Says why the buttons below are dead, at the moment they are. A disabled
            // control with no explanation is the one state a reader cannot get out of.
            Text(relayNote)
                .font(.hive(.caption2))
                .foregroundStyle(relayIsRefused ? Color.red : Color.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            // An invite in the field takes the screen over. Not a hint pointing at the button
            // below — the reader has already supplied the whole invitation, and asking them to
            // go and paste it a second time somewhere else is the same dead end in a politer
            // voice.
            if let invitation {
                Button {
                    environment.communitySheet = .join(invitation)
                } label: {
                    Label(
                        "Join \(CommunityIdentity.name(forRelay: invitation.relayURLString))",
                        systemImage: "envelope.open"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(action: create) {
                    Label("Create New Identity", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(!relayIsValid)
            }

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
            .disabled(invitation != nil)

            // The fourth way in, and the only one that works on a relay you are not already
            // a member of. It is last because the three above are what a reader with their
            // own relay came here to do; it is present because a reader with an invite link
            // has no other route (§ ``JoinCommunityModel``).
            Button {
                environment.communitySheet = .join(nil)
            } label: {
                Label("Join with an Invite", systemImage: "envelope.open")
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
            // The reduced form, not the text. A community is identified by its socket URL, so
            // handing the field's `https://…` spelling down would make the same relay pasted
            // two ways into two communities with two keys and two copies of one history.
            PasteKeyView(relayURLString: address.relayURLString ?? relayURLString)
        case .scan:
            PairingFlowView()
        }
    }

    // MARK: - Actions

    private func create() {
        guard !isBusy, let relay = address.relayURLString, relayIsValid else {
            error = .invalidRelayURL
            return
        }
        relayFocused = false
        isBusy = true
        error = nil
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

    static let relayNote =
        "Used when creating a new identity or pasting a key. Scanning a QR uses the relay "
            + "from your desktop."

    /// Names the two forms that work, because the field cannot say which one the reader was
    /// reaching for, and points at the other route — a relay that does not already know you
    /// wants an invite, not an identity (§ ``JoinCommunityModel``).
    static let relayRefusedNote =
        "That isn't a relay address Hive can use. A relay looks like wss://relay.example, "
            + "or the https:// address it serves its own pages on. If you were given an "
            + "invite link, use Join with an Invite instead."

    /// A URL with a page under it. Named separately from "not an address" because it is a
    /// different mistake with a different fix, and because the old behaviour — connecting a
    /// websocket to whatever page it named — looked to the reader like the relay itself
    /// failing to answer.
    static let relayHasAPageNote =
        "That's a web address with a page on the end, not a relay. A relay address is just "
            + "the host, like wss://relay.example — drop everything after it. An invite link "
            + "belongs here too, but this one has no invite code in it."

    /// What the field says once it is holding an invitation. It is not a correction: an
    /// invite link is the address most people are given, and this field is where they will
    /// put it.
    static let inviteNote =
        "That's an invite link. Joining with it creates your identity on that community — "
            + "you don't need a key first."
}

/// The pushable onboarding sub-flows.
enum OnboardingRoute: Hashable {
    case paste
    case scan
}
