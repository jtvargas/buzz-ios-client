import BuzzKit
import Foundation

/// Everything the join screen says: why text has not resolved into an invitation, what the
/// Join button is still waiting for, and what a relay's refusal means to the person reading it.
///
/// Its own file because ``JoinCommunityModel`` is at the length limit, and because this is the
/// one part of that screen that is purely about explaining itself: nothing here decides
/// anything, and no other state depends on it.
extension JoinCommunityModel {
    /// The sentence under the field.
    ///
    /// Not an ``error``: a half-typed link is the normal state of a text field, and calling
    /// it wrong on every keystroke shouts at somebody who is doing fine. But saying *nothing*
    /// is how a reader ends up staring at a Join button that will not light up — this field
    /// takes an invitation, and a relay address looks enough like one to be worth pasting, so
    /// that mistake is named rather than ignored.
    var linkNote: String {
        guard link == nil else { return Self.blurb }
        switch CommunityAddress(linkText) {
        case .nothingYet:
            return Self.blurb
        // A relay address is the near miss worth naming: it is a URL, it names the right host,
        // and it is what somebody told "the community is at X" will reach for.
        case .relay:
            return Self.relayNotInviteNote
        case .invitation, .unusable:
            // `.invitation` is unreachable while `link` is nil — both are read from the same
            // text by the same parser — but it is not a state this file should have to prove
            // impossible, and the general note is true of it anyway.
            return Self.notAnInviteNote
        }
    }

    /// The line under the Join button while it is grey.
    ///
    /// The whole reason ``Blocker`` is a value rather than a boolean. Each case names the
    /// control that answers it, in the words that control uses on screen, so the sentence is
    /// an instruction rather than a complaint.
    var blockedNote: String? {
        switch blocked {
        case nil: nil
        case .needsLink: nil // The field's own footer is already saying this, right above it.
        case .needsValidKey: "That isn't a valid nsec. One starts with nsec1."
        case .needsAgeAttestation:
            "This community asks you to confirm your age before joining — the switch above."
        }
    }

    /// The near miss. Says what is missing from what they pasted, and — because a relay
    /// address in this field usually means the reader is already a member of that relay
    /// somewhere else and is trying to bring the community over — names the route that
    /// needs no invite at all.
    static var relayNotInviteNote: String {
        "That's a relay address, not an invite. An invite link has a code on the end, like "
            + "https://relay.example/invite/v2.abc — ask whoever invited you for one. If "
            + "you're already a member of this relay somewhere else, use Add a relay and "
            + "sign in with that key instead."
    }

    static var notAnInviteNote: String {
        "That isn't an invite link yet. One looks like https://relay.example/invite/v2.abc."
    }

    // MARK: - Saying what happened

    /// Turns a refusal into a sentence naming what the reader can do about it.
    ///
    /// The relay's own strings are never shown. `invite_exhausted` tells someone who cannot
    /// mint an invite nothing they can act on; "ask whoever invited you for a new link"
    /// does.
    static func message(for error: InviteError) -> String {
        invitationMessage(for: error) ?? exchangeMessage(for: error)
    }

    /// The invitation itself is no good. Every one of these ends in the same place — this
    /// link will not work again, ask for another — so they are grouped.
    private static func invitationMessage(for error: InviteError) -> String? {
        switch error {
        case .expired:
            "This invite has expired. Ask whoever invited you for a new link."
        case .exhausted:
            "This invite has already been used as many times as it allows. Ask for a new link."
        case .invalidCode:
            "This relay doesn't recognise that invite."
        case .policyRequired:
            "This community's terms have to be accepted before joining, and this link's "
                + "acceptance is no longer current. Open the invite link again."
        case .policyNotAccepted:
            "This community's terms changed while you were reading them. Open the invite "
                + "link again."
        case .noPolicyConfigured:
            "This community has no terms to accept."
        default:
            nil
        }
    }

    /// The invitation may be perfectly good; the conversation with the relay is what did
    /// not complete. These are the ones where trying again is the right advice.
    private static func exchangeMessage(for error: InviteError) -> String {
        switch error {
        case .rateLimited:
            "Too many attempts. Wait a minute and try again."
        case .unreachable:
            "Couldn't reach that relay. Check your connection and try again."
        case .invalidRelayURL:
            "That link doesn't name a relay Hive can connect to."
        case let .httpStatus(status):
            "The relay refused the invite (HTTP \(status))."
        default:
            "The relay's answer wasn't something Hive could read."
        }
    }

    // MARK: - Copy

    static let blurb =
        "An invite link is how you get into a community that doesn't already know you. "
            + "Paste one here, or open it from your browser."

    /// The one thing a reader has to understand before a fresh key is created for them —
    /// the same warning the Flutter client gives at the same moment
    /// (`invite_join_sheet.dart:82`).
    static let newIdentityWarning =
        "A new key is created for this community, and this phone is the only copy of it. "
            + "Back it up from your account screen once you're in."

    /// Says the consequence of leaving it blank rather than pressing for it. Comb's screen
    /// puts the same thing in the same words for the same reason
    /// (`comb/Comb/Features/Onboarding/JoinView.swift`).
    static let displayNameBlurb =
        "Optional. Without one, people in this community see a code instead of you — you can "
            + "change it later from your account."

    static let existingIdentityBlurb =
        "The community will see this key's public identity. Use a new one if you'd rather "
            + "it not be linked to where else you use it."
}
