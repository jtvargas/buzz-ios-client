@testable import BuzzKit
import Foundation
import Testing

/// What an invite link may say, and what it may not.
///
/// # Why the refusals carry the weight here
///
/// A link is the one thing in this app that arrives from outside and ends in the phone
/// opening an authenticated socket to a host of somebody else's choosing. The accepting
/// cases below are the contract with the other two clients; the refusing ones are the
/// feature. Each is a shape that reads as one destination and resolves as another, or one
/// that is not on the public internet at all.
@Suite("Invite links")
struct InviteLinkTests {
    // MARK: - The shapes that are invites

    @Test("the canonical https link names a wss relay and a code")
    func canonicalWebLink() throws {
        let link = try #require(InviteLink.parse("https://tech.communities.buzz.xyz/invite/v2.abc123"))
        #expect(link.relayURLString == "wss://tech.communities.buzz.xyz")
        #expect(link.code == "v2.abc123")
        #expect(link.policyReceipt == nil)
        #expect(link.host == "tech.communities.buzz.xyz")
    }

    @Test("an https link on a non-default port keeps the port")
    func webLinkWithPort() throws {
        let link = try #require(InviteLink.parse("https://relay.example:7777/invite/code"))
        #expect(link.relayURLString == "wss://relay.example:7777")
        #expect(link.host == "relay.example:7777")
    }

    @Test("the app handoff carries the receipt the web page already obtained")
    func handoffCarriesReceipt() throws {
        let link = try #require(
            InviteLink.parse("buzz://join?relay=wss%3A%2F%2Frelay.example&code=v2.abc&policy_receipt=r.mac")
        )
        #expect(link.relayURLString == "wss://relay.example")
        #expect(link.code == "v2.abc")
        #expect(link.policyReceipt == "r.mac")
    }

    /// The `https` form never carries a receipt, and the `buzz` form only carries one when
    /// the relay had a policy. Both are the same value here — nothing accepted yet — and
    /// the difference between "no receipt" and "empty receipt" must not reach the claim,
    /// which would send `policy_receipt: ""` and be refused for a reason nobody could read.
    @Test("an empty receipt parameter is no receipt at all")
    func emptyReceiptIsNil() throws {
        let link = try #require(
            InviteLink.parse("buzz://join?relay=wss%3A%2F%2Frelay.example&code=abc&policy_receipt=")
        )
        #expect(link.policyReceipt == nil)
    }

    @Test("surrounding whitespace is not part of the link")
    func trimsWhitespace() throws {
        let link = try #require(InviteLink.parse("  https://relay.example/invite/abc\n"))
        #expect(link.code == "abc")
    }

    @Test("a plaintext relay is a ws relay, in a build that allows one")
    func plaintextLocalRelay() throws {
        let link = try #require(
            InviteLink.parse("http://localhost:3004/invite/abc", allowInsecureLocalRelay: true)
        )
        #expect(link.relayURLString == "ws://localhost:3004")
    }

    // MARK: - The shapes that are not

    @Test(
        "anything that is not an invite link is refused",
        arguments: [
            "",
            "not a link",
            // A relay URL, but not an invitation to anything.
            "wss://relay.example",
            // The path has to be exactly one code segment under /invite.
            "https://relay.example/invite",
            "https://relay.example/invite/",
            "https://relay.example/invite/code/extra",
            "https://relay.example/channels/abc",
            // A different app's deep link.
            "buzz://message?channel=abc&id=def",
            // Half a handoff.
            "buzz://join?relay=wss://relay.example",
            "buzz://join?code=abc",
            "buzz://join?relay=&code=abc",
            // The relay in a handoff has to be a websocket URL, not an arbitrary one.
            "buzz://join?relay=https%3A%2F%2Frelay.example&code=abc",
            "buzz://join?relay=file%3A%2F%2F%2Fetc%2Fpasswd&code=abc",
        ]
    )
    func refusesNonInvites(_ text: String) {
        #expect(InviteLink.parse(text) == nil)
    }

    /// Credentials and a fragment are the two ways a link is read by a person as one host
    /// and resolved by a URL parser as another. Neither belongs on an invite, so neither is
    /// tolerated on the outer link or on the relay nested inside a handoff.
    @Test(
        "credentials and fragments are refused, outside and inside",
        arguments: [
            "https://evil.example@relay.example/invite/abc",
            "https://user:pass@relay.example/invite/abc",
            "https://relay.example/invite/abc#fragment",
            "buzz://join?relay=wss%3A%2F%2Fevil.example%40relay.example&code=abc",
            "buzz://join?relay=wss%3A%2F%2Frelay.example%23x&code=abc",
        ]
    )
    func refusesSmuggledAuthority(_ text: String) {
        #expect(InviteLink.parse(text, allowInsecureLocalRelay: true) == nil)
    }

    /// A shipping build will not open a plaintext socket on a stranger's link, and will not
    /// be pointed at this device or the network it is sitting on. `100.64/10` is in that
    /// list because it is Tailscale's range: the owner's own relay is reached by its
    /// `.ts.net` name, and a *link* naming the numeric address is somebody else's idea.
    @Test(
        "a shipping build refuses plaintext and non-public destinations",
        arguments: [
            "http://relay.example/invite/abc",
            "http://localhost:3004/invite/abc",
            "https://127.0.0.1/invite/abc",
            "https://10.0.0.1/invite/abc",
            "https://192.168.1.1/invite/abc",
            "https://172.16.0.1/invite/abc",
            "https://100.111.202.55/invite/abc",
            "https://169.254.1.1/invite/abc",
            "https://224.0.0.1/invite/abc",
            "https://0.0.0.0/invite/abc",
            // Ambiguous spellings of an address, read differently by different resolvers.
            "https://2130706433/invite/abc",
            "https://0x7f.0x0.0x0.0x1/invite/abc",
            "https://010.0.0.1/invite/abc",
            "https://127.1/invite/abc",
            // An IPv6 literal: refused as a form, since a relay minting invites has a name.
            "https://[::1]/invite/abc",
        ]
    )
    func refusesNonPublicRelays(_ text: String) {
        #expect(InviteLink.parse(text, allowInsecureLocalRelay: false) == nil)
    }

    /// The one plaintext destination a debug build allows, and the ones it still does not:
    /// developing against a relay on this machine is worth an exception, and a private
    /// address elsewhere on the network is not the same thing.
    @Test("a debug build allows only localhost to be plaintext")
    func debugAllowsOnlyLocalhost() {
        #expect(InviteLink.parse("http://localhost/invite/abc", allowInsecureLocalRelay: true) != nil)
        #expect(InviteLink.parse("http://dev.localhost/invite/abc", allowInsecureLocalRelay: true) != nil)
        #expect(InviteLink.parse("http://192.168.1.10/invite/abc", allowInsecureLocalRelay: true) == nil)
        #expect(InviteLink.parse("http://relay.example/invite/abc", allowInsecureLocalRelay: true) == nil)
    }

    /// A public address written canonically is still a valid relay: the rule is about
    /// *which* addresses, not about refusing every literal.
    @Test("a public dotted-decimal address is allowed")
    func allowsPublicLiteral() throws {
        let link = try #require(InviteLink.parse("https://93.184.216.34/invite/abc"))
        #expect(link.relayURLString == "wss://93.184.216.34")
    }
}
