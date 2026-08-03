import BuzzKit
import SwiftUI

/// The launch onboarding hub — four ways onto Hive, ranked. Scan a pairing QR from the desktop,
/// join with an invite, create a brand-new identity, or paste an existing `nsec`. The relay
/// field is shared by Create and Paste; the Scan path takes its relay from the QR instead.
///
/// ## Why the screen is shaped this way
///
/// The routes have not changed and neither has anything they do — this is presentation. What
/// changed is that the old screen presented all four as equals under a relay field that was the
/// largest thing on it, so the first decision a reader made was about a URL they had usually
/// already been given. Now:
///
/// - **Scanning leads**, because a reader on a phone with Buzz open on their desktop is the
///   common arrival, and it is the one route that needs no relay typed at all;
/// - **the relay collapses** to a line once it holds something usable, and opens itself back up
///   the moment it does not — the field is still there, it just is not the headline;
/// - **create and paste stay in reach** as a text row rather than a fourth and fifth slab. They
///   are the routes for a reader who already has a relay of their own, which is not most people
///   opening this screen for the first time.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Whether this is a reader joining *another* community rather than arriving on Hive.
    ///
    /// The same four paths either way, which is the point — a community is a relay and an
    /// identity, and there is no third way to come by one. Flutter reuses its pairing page
    /// the same way (`PairingPage(addingCommunity: true)`). What changes is the framing: the
    /// welcome becomes a title that says what will happen, and there is a way out.
    let isAddingCommunity: Bool

    @State private var relayURLString: String
    @State private var error: IdentityGateError?
    @State private var isBusy = false
    @State private var lookup = CommunityLookup()
    /// Whether the relay editor is open. See ``relaySection`` for when it opens itself.
    @State private var relayExpanded: Bool
    @FocusState private var relayFocused: Bool

    /// - Parameter isAddingCommunity: see the property. The relay field starts empty in that
    ///   mode: the stored URL is the community already open, and prefilling it would offer
    ///   to "add" the one the reader is standing in.
    init(isAddingCommunity: Bool = false) {
        self.isAddingCommunity = isAddingCommunity
        let initialRelay = isAddingCommunity ? "" : RelayEndpoint.storedURLString
        _relayURLString = State(initialValue: initialRelay)
        // Open on arrival unless the stored relay is already usable. A reader who has to tap
        // once to reach an empty required field has been given a puzzle, not a tidy screen.
        _relayExpanded = State(initialValue: !Self.isUsableRelay(initialRelay))
    }

    /// Whether a string reduces to a relay Hive can connect to. Static so ``init`` can ask
    /// before `self` exists.
    private static func isUsableRelay(_ string: String) -> Bool {
        if case .relay = CommunityAddress(string) { return true }
        return false
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

    /// Whether the two identity routes can act. An invite in the field disables them on
    /// purpose: `Create new identity` against a relay you have an invite to would mint a
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
            // The two spacers are what compose the screen: they share whatever height is left
            // over, so the hero settles into the upper third and the actions sit against the
            // bottom on every phone, instead of both stacking under the navigation bar with a
            // third of the display left blank underneath. `minHeight` rather than `height`, so
            // Dynamic Type and the keyboard scroll rather than clip.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: isAddingCommunity ? 4 : 20)
                        hero
                        Spacer(minLength: 36)
                        controls
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    // An onboarding screen stretched edge to edge on an iPad is a hero mark
                    // with three feet of nothing on either side of it.
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
            .background { HoneycombBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
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
            // A field that stops holding a usable relay opens itself, so the reason the
            // routes below went quiet is on screen rather than folded away behind a chevron.
            .onChange(of: relayIsValid) { _, isValid in
                if !isValid { relayExpanded = true }
            }
            .overlay {
                if isBusy { ProgressView().controlSize(.large) }
            }
            .animation(.default, value: error)
            .disabled(isBusy)
        }
        // The hero owns its appearance: an amber lattice glowing out of near-black is the
        // screen, and its light-mode counterpart is a grey mesh on white. Applied to the whole
        // stack so the pushed scan and paste steps do not flip back mid-flow.
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var hero: some View {
        OnboardingHero(
            title: isAddingCommunity ? "Add a community" : "Welcome to Hive",
            accentLine: isAddingCommunity ? nil : "for Buzz",
            blurb: isAddingCommunity ? Self.addingBlurb : Self.welcomeBlurb,
            markSize: isAddingCommunity ? 48 : 68
        )
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if address.relayURLString != nil {
                CommunityCard(
                    name: lookup.name,
                    icon: lookup.icon,
                    isChecking: lookup.isChecking,
                    isVerified: lookup.isVerified
                )
            }
            OnboardingRelayField(
                relayURLString: $relayURLString,
                isExpanded: $relayExpanded,
                note: relayNote,
                isRefused: relayIsRefused,
                isFocused: $relayFocused
            )
            actions
            if let error {
                Text(error.message)
                    .font(.hive(.footnote))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Error: \(error.message)")
            }
        }
        .animation(.snappy(duration: 0.25), value: relayExpanded)
        .animation(.snappy(duration: 0.25), value: invitation != nil)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            // An invite in the field takes the screen over. Not a hint pointing at a button
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
                .buttonStyle(.glass)
            } else {
                // The lead route: the only one that needs nothing typed, and the one a reader
                // with Buzz already open on their desktop is here to take.
                //
                // Glass rather than `.glassProminent`, and *the same* glass as the route under
                // it. Prominent fills the capsule with flat accent, and a solid amber slab over
                // a lit amber lattice is the one shape on this screen that stops the pattern
                // dead — it reads as a sticker on the artwork rather than as a control sitting
                // in it. A tinted glass was tried in between and is the same objection in a
                // paler shade. Rank now comes from order and from the glyph, which is what it
                // comes from everywhere else in the app.
                NavigationLink(value: OnboardingRoute.scan) {
                    Label("Scan QR from Desktop", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                // The only route that works on a relay you are not already a member of, and
                // the one an invite link is for (§ ``JoinCommunityModel``).
                Button {
                    environment.communitySheet = .join(nil)
                } label: {
                    Label("Join with an Invite", systemImage: "envelope.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }

            moreWaysIn
                .padding(.top, 6)
        }
        .controlSize(.large)
    }

    /// Create and paste. A text row rather than two more slabs: both need a relay of your own,
    /// which is the less common arrival, and neither is hidden — they are one tap from here,
    /// same as they were when they were buttons.
    private var moreWaysIn: some View {
        HStack(spacing: 0) {
            Button(action: create) {
                Text("Create new identity")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .contentShape(.rect)
            }
            .disabled(!relayIsValid)
            .opacity(relayIsValid ? 1 : 0.35)

            Text("·")
                .foregroundStyle(.white.opacity(0.3))

            NavigationLink(value: OnboardingRoute.paste) {
                Text("Paste existing key")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .contentShape(.rect)
            }
            .disabled(invitation != nil)
            .opacity(invitation == nil ? 1 : 0.35)
        }
        .font(.hive(.footnote, weight: .medium))
        .foregroundStyle(.hiveAccent)
        .buttonStyle(.plain)
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
    /// Names the two routes the screen leads with, in the order it leads with them. The old
    /// line ("Connect your identity to start messaging on the Buzz relay") described the
    /// screen's purpose rather than what to do next, which a reader can already see.
    static let welcomeBlurb =
        "Scan the code on your desktop, or paste an invite link to connect this phone."
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
