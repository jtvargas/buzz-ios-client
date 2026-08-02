import BuzzKit
import Foundation

/// What a reader typed when asked where a community is.
///
/// # Why one type rather than a validator on each field
///
/// There are two fields on two screens that take an address — `Add community`'s relay field
/// and the join screen's invite field — and the near miss on each of them is *the other one's
/// input*. Somebody told "the community is at buzzdir.communities.buzz.xyz" pastes a relay
/// address into the invite field; somebody handed an invite link pastes the whole thing into
/// the relay field. Both were dead ends: the invite field said nothing at all, and the relay
/// field took the invite link's **path** as part of the address and opened a websocket to a
/// web page — which is exactly the "it never reached the relay" this fixes.
///
/// So the reading is done once, here, and each screen decides what to do with the answer
/// rather than deciding what the text was. Neither field is wrong to have text of the other
/// kind in it; the screen just has to know which it is holding.
enum CommunityAddress: Equatable {
    /// Nothing usable yet — including an empty field, which is where everybody starts and is
    /// not a refusal.
    case nothingYet
    /// A relay origin, reduced to the socket form the engine connects on. Path-free by
    /// construction: a relay is a host, and anything under it is a page.
    case relay(String)
    /// An invitation, in any of the forms § ``BuzzKit/InviteLink/parse(_:allowInsecureLocalRelay:)``
    /// takes.
    case invitation(InviteLink)
    /// Text that names something, and not a community.
    case unusable(Refusal)

    /// Why an address was not usable, in the terms the reader can act on.
    enum Refusal: Equatable {
        /// A URL with a page under it, which is not a relay and is not an invite either —
        /// the relay's own web app, most likely, or an invite link that lost its code.
        case hasAPageUnderIt
        /// Not a URL this app has any reading for.
        case notAnAddress
    }

    /// Reads a line of text once.
    ///
    /// The order is deliberate: an invitation is checked **first**, because an invite link is
    /// also a URL whose scheme and host would satisfy the relay rule, and taking it as a relay
    /// is the failure this exists to prevent. Only text that is not an invitation is offered
    /// the relay reading.
    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .nothingYet
            return
        }
        if let invitation = InviteLink.parse(trimmed) {
            self = .invitation(invitation)
            return
        }
        guard let components = URLComponents(string: trimmed), components.scheme != nil else {
            self = .unusable(.notAnAddress)
            return
        }
        // A relay is an origin. `RelayEndpoint.websocketURLString(fromAnyRelay:)` keeps a path
        // — it has to, because it also converts the HTTP base a paired desktop sends — so the
        // path is refused here, at the field, rather than there.
        guard components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil
        else {
            self = .unusable(.hasAPageUnderIt)
            return
        }
        guard var relay = RelayEndpoint.websocketURLString(fromAnyRelay: trimmed) else {
            self = .unusable(.notAnAddress)
            return
        }
        // A lone trailing slash is the same origin. `Community.relayIdentity(of:)` already
        // strips it before comparing, so this changes no decision — it keeps the value this
        // type hands out an origin, which is what everything downstream reads it as.
        while relay.hasSuffix("/") { relay.removeLast() }
        self = .relay(relay)
    }

    /// The relay this address names, whichever kind it is — the origin itself, or the one the
    /// invitation is to. `nil` when there is nothing to look up.
    ///
    /// This is what a community lookup is keyed on, so a card resolves the moment either
    /// field holds something that names a host.
    var relayURLString: String? {
        switch self {
        case let .relay(relay): relay
        case let .invitation(link): link.relayURLString
        case .nothingYet, .unusable: nil
        }
    }
}
