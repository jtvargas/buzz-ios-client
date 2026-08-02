import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// What a phone can learn about a community before it is in one.
///
/// The point of the fetch behind these: a relay with `require_relay_membership` set answers
/// `403` to its whole API from a key it does not know, so the information document is the only
/// thing a reader deciding whether to join can be shown. These assert what the card says in
/// each of the four states a host can leave it in — and, as much, what it refuses to say.
@MainActor
@Suite(.serialized)
struct CommunityLookupTests {
    // MARK: - The community behind the link

    /// The card at the top. It resolves from the link alone, with no identity and no
    /// membership — which is the whole point, because a closed relay answers `403` to every
    /// other route until an invite has been redeemed.
    @Test func theCardFillsInFromTheLinkBeforeAnyIdentityExists() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let lookup = JoinHarness.lookup(RelayInfo(
            icon: "https://cdn.example/icon.png",
            software: RelayInfo.buzzSoftware
        ))
        let model = JoinHarness.model(
            environment,
            transport: ScriptedTransport(answers: JoinHarness.openRelay),
            lookup: lookup
        )

        model.linkText = "https://buzzdir.communities.buzz.xyz/invite/v2.abc"
        try await JoinHarness.settle(lookup)

        #expect(lookup.isVerified)
        #expect(lookup.icon == .remote(URL(string: "https://cdn.example/icon.png")!))
        // The name is the host's, derived exactly as Buzz Desktop derives it on the same
        // relay — never the relay's own `name`, which is the same string everywhere.
        #expect(lookup.name == "buzzdir")
        #expect(model.canContinue)
    }

    /// A host that will not answer leaves the card unverified and gates nothing. An operator
    /// running a relay behind something that does not serve the document must still be able
    /// to join their own community.
    @Test func aHostThatSaysNothingIsNotVerifiedAndBlocksNothing() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let lookup = JoinHarness.lookup(nil)
        let model = JoinHarness.model(
            environment,
            transport: ScriptedTransport(answers: JoinHarness.openRelay),
            lookup: lookup
        )

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(lookup)

        #expect(!lookup.isVerified)
        #expect(lookup.icon == nil)
        #expect(model.canContinue)
    }

    /// The honest half of the badge: a plain Nostr relay answers the same document and has no
    /// invite API at all.
    @Test func aRelayThatIsNotBuzzIsNotCalledAVerifiedCommunity() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let lookup = JoinHarness.lookup(RelayInfo(software: "git+https://github.com/hoytech/strfry.git"))
        let model = JoinHarness.model(
            environment,
            transport: ScriptedTransport(answers: JoinHarness.openRelay),
            lookup: lookup
        )

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(lookup)

        #expect(!lookup.isVerified)
    }

    /// Every keystroke inside a pasted code names the same host. Without the guard the card
    /// would fire a request per character and flicker through `Checking…` for the length of it.
    @Test func typingInsideACodeDoesNotAskTheHostAgain() async throws {
        let lookup = JoinHarness.lookup(RelayInfo(software: RelayInfo.buzzSoftware))

        lookup.look(at: "wss://relay.example")
        try await JoinHarness.settle(lookup)
        #expect(lookup.isVerified)

        lookup.look(at: "wss://relay.example")
        // Not re-checking: the answer it already has is about this host.
        #expect(!lookup.isChecking)
        #expect(lookup.isVerified)

        lookup.look(at: "wss://other.example")
        #expect(lookup.isChecking)
        #expect(!lookup.isVerified)
    }

    /// `Add community`'s field is typed into, and every prefix of `wss://relay.example` that
    /// has a host **is** a host — so without a wait, typing one address puts a request to a
    /// dozen partial hostnames on the wire. Asserted on what the transport was asked, because
    /// the states in between all look identical from the card.
    @Test func typingAnAddressAsksOnlyTheHostItSettlesOn() async throws {
        let transport = RecordingRelayInfoTransport()
        let lookup = CommunityLookup(debounce: .milliseconds(60)) { relay in
            RelayInfoClient(relayURLString: relay, transport: transport)
        }

        // Typed, not pasted: the pause between keystrokes is the whole subject. Without it
        // the four calls run in one synchronous burst, every abandoned task is cancelled
        // before it ever executes, and the assertion below would hold with no wait at all.
        for prefix in ["wss://r", "wss://re", "wss://rel", "wss://relay.example"] {
            lookup.look(at: prefix)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await JoinHarness.settle(lookup)

        #expect(await transport.hosts == ["relay.example"])
        #expect(lookup.isVerified)
    }
}
