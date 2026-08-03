import SwiftUI

/// Bringing an existing `nsec` onto this phone, in two steps.
///
/// The key is held only in the field until submit, committed to the Keychain, and never retained
/// afterwards — unchanged, and the reason this file's rewrite is presentation only.
///
/// # Why two steps and not the `Form` this was
///
/// It was a grouped table with a relay field and a secret field on it, which is the right shape
/// for several unrelated settings on one screen and the wrong one for this: these are two halves
/// of one sentence — *this key, on that relay* — and the table drew them as peers with a system
/// grey slab over the lattice the reader had just arrived from. Now it walks the way
/// ``CreateIdentityView`` and ``JoinCommunityView`` do, on the same honeycomb and out of the same
/// glass cards.
///
/// # Why there is no profile step
///
/// The other two walks ask for a name and a picture. This one must not. A kind-0 is replaceable
/// and Hive writes a fresh one on arrival rather than merging into what the relay already holds
/// (§ ``AppEnvironment/announceArrivalProfile(displayName:emoji:color:)``), so asking a reader
/// who is bringing an identity they already use to fill in a name here would be offering to
/// overwrite the profile that identity already has. The account screen is where an existing key
/// changes its own name, with its current values in front of it.
struct PasteKeyView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var step: Step = .relay
    /// Prefilled from the hub's relay field; editable here.
    @State private var relayURLString: String
    @State private var nsec = ""
    @State private var error: IdentityGateError?
    @State private var lookup = CommunityLookup()
    @FocusState private var focused: JoinField?

    init(relayURLString: String) {
        _relayURLString = State(initialValue: relayURLString)
    }

    /// `working` is not a third place to be — it is the key step with the connection being made.
    enum Step: Int, Equatable {
        case relay
        case key
        case working
    }

    var body: some View {
        IdentityWizardScaffold(
            index: min(step.rawValue, Step.key.rawValue),
            count: 2,
            title: title,
            blurb: blurb,
            error: error?.message,
            blockedNote: blockedNote,
            actionTitle: actionTitle,
            canContinue: canContinue,
            isWorking: step == .working,
            action: advance
        ) {
            switch step {
            case .relay:
                IdentityRelayStep(
                    relayURLString: $relayURLString,
                    focused: $focused,
                    lookup: lookup,
                    isUsable: relayIsUsable
                )
            case .key, .working:
                keyStep
            }
        }
        .navigationTitle("Existing key")
        // From the second step on, Back means "back one step", not "off this screen" — see
        // ``CreateIdentityView``.
        .navigationBarBackButtonHidden(step != .relay)
        .toolbar {
            if step != .relay {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        focused = nil
                        stepBack()
                    }
                    .disabled(step == .working)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
            }
        }
        .onChange(of: reducedRelay, initial: true) { _, relay in
            lookup.look(at: relay)
        }
        .interactiveDismissDisabled(step == .working)
    }

    // MARK: - The key

    @ViewBuilder
    private var keyStep: some View {
        JoinCard {
            HStack(spacing: 12) {
                CommunityMark(name: lookup.name, icon: lookup.icon, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lookup.name)
                        .font(.hive(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Signing in with a key you already have")
                        .font(.hive(.caption2))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        JoinCard(spacing: 12) {
            JoinCardLabel(text: "SECRET KEY", systemImage: "key")
            SecureField("", text: $nsec, prompt: Self.nsecPrompt)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .nsec)
                .submitLabel(.go)
                .onSubmit(advance)
                .joinFieldBackground()
            JoinCardNote(text: Self.custodyNote)
        }
    }

    private static let nsecPrompt = Text("nsec1…").foregroundStyle(.white.opacity(0.3))

    /// Says where the secret goes, on the step it is typed on. It is the one claim a reader
    /// pasting a private key into an app is owed before they paste it, not after.
    static let custodyNote =
        "Your nsec is stored only in this device's Keychain and never leaves it. This "
            + "community will keep the name and picture this key already has."

    // MARK: - What the step says

    private var title: String {
        switch step {
        case .relay: "Where you're going"
        case .key, .working: "The key that signs for you"
        }
    }

    private var blurb: String {
        switch step {
        case .relay: "A community is a relay. Point Hive at the one this key belongs on."
        case .key, .working: "Paste the secret key you already use. Nothing is stored until "
            + "you tap Connect."
        }
    }

    private var actionTitle: String {
        switch step {
        case .relay: "Next"
        case .key: "Connect"
        case .working: "Connecting…"
        }
    }

    private var blockedNote: String? {
        step == .relay && !relayIsUsable && !relayURLString.isEmpty
            ? "That isn't a relay address Hive can use."
            : nil
    }

    // MARK: - The address, and the key

    private var reducedRelay: String? {
        CommunityAddress(relayURLString).relayURLString
    }

    private var relayIsUsable: Bool {
        if case .relay = CommunityAddress(relayURLString) { return true }
        return false
    }

    private var trimmedSecret: String {
        nsec.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        switch step {
        case .relay: relayIsUsable
        case .key: !trimmedSecret.isEmpty
        case .working: false
        }
    }

    // MARK: - Moving

    private func advance() {
        focused = nil
        error = nil
        switch step {
        case .relay:
            guard relayIsUsable else { return }
            withAnimation(.snappy) { step = .key }
        case .key:
            submit()
        case .working:
            return
        }
    }

    private func stepBack() {
        guard step == .key else { return }
        withAnimation(.snappy) { step = .relay }
    }

    /// Unstructured on purpose: signing in tears this screen down, and a `.task`-owned child
    /// would be cancelled by that teardown while the engine it started was still coming up.
    private func submit() {
        guard let relay = reducedRelay, relayIsUsable, !trimmedSecret.isEmpty else { return }
        let secret = nsec
        step = .working
        Task {
            let failure = await environment.submitIdentity(relayURLString: relay, nsec: secret)
            error = failure
            if failure == nil {
                nsec = ""
            } else {
                step = .key
            }
        }
    }
}
