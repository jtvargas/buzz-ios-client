import BuzzKit
import SwiftUI

/// Making a brand-new identity on a relay, in three steps.
///
/// # Why this is a screen now
///
/// It was a text button on the hero. Pressing it minted a secp256k1 key, committed it to the
/// Keychain and signed the reader in, against whatever address happened to be sitting in the
/// relay field — no confirmation of where, no chance to say who they were, and no statement
/// anywhere that the phone in their hand had just become the only copy of a key. That last part
/// is the one this app owes people a sentence about, and there was nowhere to put it.
///
/// So: **where you're going**, **who you'll be there**, **the key**. The same three the join
/// walks (§ ``JoinCommunityModel/Step``) and the same order, because it is the same arrival with
/// a different door — and the profile step is literally the join's, reused
/// (``JoinCommunityProfileStep``), so a reader who does both meets one screen twice rather than
/// two screens that ask the same thing differently.
struct CreateIdentityView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var step: Step = .relay
    @State private var relayURLString: String
    @State private var displayName = ""
    @State private var avatarEmoji: String?
    @State private var avatarColor = EmojiAvatar.defaultColor
    @State private var error: IdentityGateError?
    @State private var lookup = CommunityLookup()
    @FocusState private var focused: JoinField?

    /// - Parameter relayURLString: the hero's field, in its reduced socket form. Editable here:
    ///   this step is the one place the address is presented as a question, and a reader who
    ///   reached it from a collapsed row on the previous screen may well be correcting it.
    init(relayURLString: String) {
        _relayURLString = State(initialValue: relayURLString)
    }

    /// Where you're going, who you'll be, and the key that signs for you.
    ///
    /// `working` is not a fourth place to be — it is the last step with the key being minted, and
    /// numbering it would make the bars jump while the screen in front of them did not change.
    enum Step: Int, Equatable {
        case relay
        case profile
        case key
        case working
    }

    var body: some View {
        IdentityWizardScaffold(
            index: min(step.rawValue, Step.key.rawValue),
            count: 3,
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
            case .profile:
                JoinCommunityProfileStep(
                    displayName: $displayName,
                    emoji: $avatarEmoji,
                    color: $avatarColor,
                    focused: $focused
                )
            case .key, .working:
                keyStep
            }
        }
        .navigationTitle("New identity")
        // From the second step on, Back means "back one step", not "off this screen". The system
        // control cannot mean both, so it is replaced rather than sat beside: two back buttons,
        // one of which silently abandons three answered steps, is the worse of the two problems.
        .navigationBarBackButtonHidden(step != .relay)
        .toolbar {
            if step != .relay {
                ToolbarItem(placement: .topBarLeading) {
                    // Live while the key is being minted, on purpose. The system's own back
                    // button is hidden from the second step on, so this is the *only* way off
                    // this screen — and `createIdentity` waits on a relay coming up, which can
                    // hang. Disabling it here would trap the reader behind a spinner with the
                    // navigation control they would normally reach for taken away. The walk
                    // that was replaced could always be popped mid-submit; so can this one.
                    Button("Back") {
                        focused = nil
                        stepBack()
                    }
                }
            }
            // The button that hands the keyboard back. The plain `.keyboard` placement, which is
            // *not* the one ``ConversationScaffold`` forbids — that prohibition is about the
            // conversation shell, which does its own keyboard avoidance and would double-count.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
            }
        }
        // Driven from the *reduced* relay rather than from the text, so a card resolves once per
        // host and not once per keystroke.
        .onChange(of: reducedRelay, initial: true) { _, relay in
            lookup.look(at: relay)
        }
        // A key being minted must not be interrupted by a drag on the sheet this walk is inside
        // when it is reached from `Add a community`.
        .interactiveDismissDisabled(step == .working)
    }

    // MARK: - The last step

    /// What is about to happen, and the one sentence this route never said.
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
                    Text(joiningAs)
                        .font(.hive(.caption2))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let avatarEmoji {
                    Circle()
                        .fill(Color(avatarHex: avatarColor) ?? .white)
                        .frame(width: 34, height: 34)
                        .overlay { Text(avatarEmoji).font(.hive(fixedSize: 17, relativeTo: .body)) }
                        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        JoinCard(spacing: 12) {
            JoinCardLabel(text: "YOUR NEW KEY", systemImage: "key")
            JoinCardNote(text: JoinCommunityModel.newIdentityWarning)
        }
    }

    private var joiningAs: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Joining without a name" : "Joining as \(name)"
    }

    // MARK: - What the step says

    private var title: String {
        switch step {
        case .relay: "Where you're going"
        case .profile: "Who you'll be here"
        case .key, .working: "The key that signs for you"
        }
    }

    private var blurb: String {
        switch step {
        case .relay: "A community is a relay. Point Hive at the one you were given."
        case .profile: "Your name and picture in this community. Both are only for this one, "
            + "and both can be changed later."
        case .key, .working: "Hive is about to make a key for you here. Nothing is created "
            + "until you tap Create."
        }
    }

    private var actionTitle: String {
        switch step {
        case .relay, .profile: "Next"
        case .key: "Create"
        case .working: "Creating…"
        }
    }

    private var blockedNote: String? {
        step == .relay && !relayIsUsable && !relayURLString.isEmpty ? relayRefusal : nil
    }

    /// Names the route for the address a reader most often has instead of a relay's.
    private var relayRefusal: String {
        if case .invitation = CommunityAddress(relayURLString) {
            return "That's an invite link, not a relay. Go back and use Join with an Invite — "
                + "it makes your identity for you."
        }
        return "That isn't a relay address Hive can use."
    }

    // MARK: - The address

    private var reducedRelay: String? {
        CommunityAddress(relayURLString).relayURLString
    }

    private var relayIsUsable: Bool {
        if case .relay = CommunityAddress(relayURLString) { return true }
        return false
    }

    private var canContinue: Bool {
        switch step {
        case .relay: relayIsUsable
        // Both answers are optional on purpose — a step that could hold the reader up over a
        // name would be demanding something neither the relay nor this app requires.
        case .profile, .key: true
        case .working: false
        }
    }

    // MARK: - Moving

    private func advance() {
        focused = nil
        error = nil
        switch step {
        case .relay:
            withAnimation(.snappy) { step = .profile }
        case .profile:
            withAnimation(.snappy) { step = .key }
        case .key:
            create()
        case .working:
            return
        }
    }

    /// Mints the key, then announces the profile.
    ///
    /// Unstructured on purpose, the same way the join's submit is: signing in tears this screen
    /// down, and a `.task`-owned child would be cancelled by that teardown while the engine it
    /// started was still coming up.
    private func create() {
        guard let relay = reducedRelay, relayIsUsable else {
            error = .invalidRelayURL
            return
        }
        step = .working
        Task {
            let failure = await environment.createIdentity(relayURLString: relay)
            if let failure {
                error = failure
                // Only if the reader is still watching this run. They can walk back out of
                // `working` while it is in flight, and yanking them forward onto a step they
                // deliberately left is worse than letting the error wait for them there.
                if step == .working { step = .key }
                return
            }
            // Safe here in a way it is not on the paste route: this key was minted a moment ago
            // and has no profile on the relay for a fresh kind-0 to overwrite. See
            // ``AppEnvironment/announceArrivalProfile(displayName:emoji:color:)``.
            await environment.announceArrivalProfile(
                displayName: displayName,
                emoji: avatarEmoji,
                color: avatarColor
            )
        }
    }

    /// Back one step, keeping everything answered. This is a step back to re-read or re-answer
    /// something, not a cancellation — leaving the walk entirely is the system's own back
    /// button, which is what the first step still shows.
    private func stepBack() {
        switch step {
        case .profile: withAnimation(.snappy) { step = .relay }
        // From `working` it is the key step that is behind you — the mint is *on* that step, not
        // a place of its own. The task carries on; it just no longer owns where the reader is.
        case .key, .working: withAnimation(.snappy) { step = .profile }
        case .relay: return
        }
    }
}
