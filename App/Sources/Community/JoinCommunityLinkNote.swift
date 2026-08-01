import Foundation

/// What the join screen says about text that has not resolved into an invitation.
///
/// Its own file because ``JoinCommunityModel`` is at the length limit, and because this is
/// the one part of that screen that is purely about explaining itself: nothing here decides
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
        guard link == nil, !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.blurb
        }
        // A relay address is the near miss worth naming: it is a URL, it names the right
        // host, and it is what somebody told "the community is at X" will reach for.
        // Anything with a page under it is some other link, and gets the general note.
        return Self.namesARelayAndNothingElse(linkText) ? Self.relayNotInviteNote : Self.notAnInviteNote
    }

    /// Whether this is a relay origin — a scheme and a host, and no page under it.
    private static func namesARelayAndNothingElse(_ text: String) -> Bool {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.path.isEmpty || components.path == "/"
        else { return false }
        return true
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
}
