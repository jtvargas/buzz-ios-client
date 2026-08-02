import BuzzKit
import Foundation
import NostrCore

/// What the button on each step of the join is waiting for, and what it says.
///
/// Its own file for the reason ``JoinCommunityGuidance`` is: ``JoinCommunityModel`` is at the
/// length limit, and this is a coherent piece to lift out — every member here is read-only and
/// derived. Nothing in this file moves the reader between steps; that stays beside the state it
/// mutates, because ``JoinCommunityModel/step`` is `private(set)` and is meant to be.
extension JoinCommunityModel {
    /// What the button on **this step** is still waiting for, or `nil` when it is waiting for
    /// the tap.
    ///
    /// Written as the *reason* rather than as a boolean because the screen has to say it. A
    /// Join button that is grey with nothing on screen explaining it is a state a reader
    /// cannot get out of — it was reported as "it stays disabled", twice, about two different
    /// causes on two different screens, which is exactly what an unexplained control looks
    /// like from outside.
    ///
    /// Per step, and that is the point of splitting them: a reader on the first screen is
    /// never held up by a key they have not been asked for yet, and one on the second is
    /// never held up by terms they agreed to a screen ago.
    var blocked: Blocker? {
        switch step {
        case .needsLink:
            return .needsLink
        case .community:
            // Already a member: nothing else on the screen is being asked for, because the
            // operation is opening rather than joining.
            if alreadyJoined != nil { return nil }
            // What the relay requires of a joiner is the reader's to answer, so the button
            // waits for it rather than the relay refusing after the fact — but only when it
            // has not already been answered elsewhere. A handoff carrying a receipt has been
            // through this screen's equivalent in a browser, and asking twice would suggest
            // the first time did not count.
            guard link?.policyReceipt == nil else { return nil }
            if policy?.ageAttestationRequired == true, !ageConfirmed {
                return .needsAgeAttestation
            }
            if publishesDocuments, !termsAccepted { return .needsTermsAccepted }
            return nil
        case .identity:
            if identity == .existing,
               (try? PrivateKey(nsec: nsec.trimmingCharacters(in: .whitespacesAndNewlines))) == nil {
                return .needsValidKey
            }
            return nil
        case .joining:
            return nil
        }
    }

    /// Whether the button on this step can be pressed.
    var canContinue: Bool { blocked == nil }

    /// Whether this community publishes anything to agree *to*. A relay with an age
    /// requirement and no documents asks for the attestation alone — putting an
    /// `I agree to the terms` switch over two absent documents would be asking for consent to
    /// nothing. Desktop draws its own agreement row on the same condition
    /// (`JoinPolicyNotice.tsx:60`).
    var publishesDocuments: Bool {
        policy?.termsMarkdown != nil || policy?.privacyMarkdown != nil
    }

    /// The things a join can be waiting for. One case per control on the screen, so the
    /// sentence under the button can point at the one that is not answered yet.
    enum Blocker: Equatable {
        case needsLink
        case needsValidKey
        case needsAgeAttestation
        case needsTermsAccepted
    }

    /// What the button says. Named here rather than in the view because the *operation*
    /// changes with the state, not just the wording.
    var actionTitle: String {
        if alreadyJoined != nil { return "Open" }
        switch step {
        case .needsLink, .community: return "Next"
        case .identity: return "Join"
        case .joining: return "Joining…"
        }
    }

    /// Whether there is a screen behind this one to go back to.
    var canGoBack: Bool { step == .identity }
}
