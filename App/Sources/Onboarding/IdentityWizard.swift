import SwiftUI

/// The shell the two identity walks are drawn in, and the step they share.
///
/// # Why these two became walks at all
///
/// `Create new identity` was not a screen. It was a text button on the hero that minted a key
/// and signed you in on the spot, on whatever address happened to be in the relay field — the
/// fastest route in the app and the only one that asked nothing and confirmed nothing. `Paste
/// existing key` was a `Form`: two fields on the system's own grey table, dropped on top of the
/// lattice, reached from a screen that no longer looks anything like it.
///
/// Both now walk the same way ``JoinCommunityView`` does, on the same honeycomb and out of the
/// same glass cards (``JoinCommunityChrome``), because they are the same kind of thing: you are
/// arriving somewhere, and the app is about to hold a key for you there. The pieces live here
/// rather than in `JoinCommunityChrome` because that file is the *cards*; this is the page they
/// are laid out on, and only the onboarding walks use it — the join has its own copy of this
/// layout wired to its model.
struct IdentityWizardScaffold<Content: View>: View {
    let index: Int
    let count: Int
    let title: String
    let blurb: String
    /// The failure to draw under the cards, if there is one.
    let error: String?
    /// Why the button below is grey, at the moment it is. A dead control with nothing
    /// explaining it is the one state a reader cannot get out of.
    var blockedNote: String?
    let actionTitle: String
    let canContinue: Bool
    /// Whether the walk is currently talking to a relay: spins the button and freezes the cards.
    let isWorking: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        // A `VStack` rather than a `safeAreaInset`, so the button takes its height out of the
        // layout instead of overlaying the scroll: the last card is then scrollable clear of it
        // rather than resting permanently underneath.
        VStack(spacing: 0) {
            steps
            actionBar
        }
        .background { HoneycombBackground() }
        .navigationBarTitleDisplayMode(.inline)
        // The step's own heading is the title, at the size a title deserves. A second one in the
        // bar would name the same thing twice, and the bar's material would put a grey band
        // across the top of the lattice to do it.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }

    private var steps: some View {
        ScrollView {
            VStack(spacing: 14) {
                JoinStepHeader(index: index, count: count, title: title, blurb: blurb)
                    .padding(.bottom, 2)

                content

                if let error {
                    JoinCard {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.hive(.footnote))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)
            // An onboarding screen stretched edge to edge on an iPad is one card with three feet
            // of nothing on either side of it.
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .disabled(isWorking)
        // The step is what the whole screen is about, so it is the one thing worth animating:
        // the cards swap rather than cutting. Scoped to the index alone — animating on every
        // change would put a movement under each keystroke in the fields.
        .animation(.snappy, value: index)
    }

    /// The one control that moves the screen on, pinned under the steps rather than scrolling
    /// with them — on a step whose content is optional a reader must never have to scroll to
    /// find the way forward.
    private var actionBar: some View {
        VStack(spacing: 8) {
            if let blockedNote {
                JoinCardNote(text: blockedNote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: action) {
                HStack(spacing: 6) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Text(actionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            // Glass, not `.glassProminent`: a flat accent slab over a lit amber lattice reads as
            // a sticker on the artwork rather than as a control sitting in it, which is the call
            // the welcome screen's two routes and the join's own button already make.
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(!canContinue || isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: blockedNote)
    }
}

// MARK: - The step both walks open on

/// Which community this is, by address — the first step of creating a key and of pasting one.
///
/// The hero has a relay field and both routes are reached from it, so this is usually a
/// confirmation rather than a question. It is still a step of its own, for the reason the join
/// has one: the address decides which community the key about to be committed will belong to,
/// and that was previously settled by a collapsed row on a screen the reader had already left.
/// The card resolves the relay's *name* while they look at it, which is the form the answer is
/// worth checking in.
struct IdentityRelayStep: View {
    @Binding var relayURLString: String
    @FocusState.Binding var focused: JoinField?
    /// The name and icon behind the address, resolved as it is typed.
    let lookup: CommunityLookup
    /// Whether what is in the field reduces to a relay Hive can connect to.
    let isUsable: Bool

    var body: some View {
        if isUsable {
            CommunityCard(
                name: lookup.name,
                icon: lookup.icon,
                isChecking: lookup.isChecking,
                isVerified: lookup.isVerified
            )
        }
        JoinCard {
            JoinCardLabel(text: "RELAY", systemImage: "dot.radiowaves.left.and.right")
            TextField("", text: $relayURLString, prompt: Self.prompt)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focused, equals: .relay)
                .joinFieldBackground()
            JoinCardNote(text: Self.note)
        }
    }

    /// `verbatim` is load-bearing: `Text` parses a string literal as Markdown, and Markdown
    /// autolinks a bare URL — so the plain initialiser draws this placeholder as a live blue
    /// link, which is both the wrong colour and a claim that the example address is tappable.
    private static let prompt = Text(verbatim: "wss://relay.example")
        .foregroundStyle(.white.opacity(0.3))

    /// Names both forms that work, because a reader who has one written down has it in whichever
    /// of the two they were given — and points at the route for the address that is neither.
    static let note =
        "A community is a relay. Either form works: the socket address (wss://relay.example) "
            + "or the https:// address it serves its own pages on. An invite link belongs in "
            + "Join with an Invite instead."
}
