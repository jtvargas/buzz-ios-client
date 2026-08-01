import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// What the join screen decides before it talks to anything.
///
/// These drive the real ``JoinCommunityModel`` against a scripted relay. What they reach is
/// every decision the screen makes on the reader's behalf: which link is an invitation, what
/// has to be supplied before the button means anything, whether the terms step runs at all,
/// and whether the code is spent on a community this phone is already in.
///
/// The assertions stop at the claim, because that is the last thing this object owns — past
/// it, ``AppEnvironment/joinCommunity(relayURLString:key:)`` takes over and is tested by
/// ``CommunitySwitchTests``. The *code* does not stop there: a scripted success runs on into
/// a real Keychain write and a real engine start against a relay that does not exist, which
/// is why ``JoinHarness.forget(_:_:)`` has a second half.
@MainActor
@Suite(.serialized)
struct JoinCommunityModelTests {
    // MARK: - Reading the link

    @Test func aLinkThatIsNotAnInviteLeavesTheScreenWaiting() {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport())

        model.linkText = "https://relay.example/channels/abc"

        #expect(model.step == .needsLink)
        #expect(model.link == nil)
        #expect(!model.canJoin)
        // Not an error: a half-typed link is the normal state of a text field, and calling
        // it wrong on every keystroke is how a form shouts at someone who is doing fine.
        #expect(model.error == nil)
    }

    @Test func anInviteLinkNamesTheRelayItWillJoin() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.openRelay)
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/v2.abc"
        try await JoinHarness.settle(model)

        #expect(model.step == .reviewing)
        #expect(model.link?.relayURLString == "wss://relay.example")
        #expect(model.link?.code == "v2.abc")
        #expect(model.policy == nil)
        #expect(model.canJoin)
    }

    /// The text field reports a change on every keystroke. Re-adopting on each one would
    /// cancel the policy read and start another, for ever, while the reader watches a
    /// spinner that never stops.
    @Test func retypingTheSameLinkDoesNotAskTheRelayAgain() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: [JoinHarness.policyPath: [
            (JoinHarness.data("{}"), 200), (JoinHarness.data("{}"), 200),
        ]])
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)
        model.linkText = "https://relay.example/invite/abc "
        try await JoinHarness.settle(model)

        #expect(await transport.callCount(for: JoinHarness.policyPath) == 1)
    }

    /// The field shows an invite in its `https` form, and that form carries no receipt. A
    /// write-back of text the reader never edited — SwiftUI does them — must not turn a
    /// one-tap handoff into the terms screen, nor drop the acceptance already made in a
    /// browser.
    @Test func aWriteBackOfUnchangedTextKeepsTheAcceptanceTheHandoffCarried() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: true))
        let link = try #require(
            InviteLink.parse("buzz://join?relay=wss%3A%2F%2Frelay.example&code=abc&policy_receipt=web.mac")
        )
        let model = JoinHarness.model(environment, transport: transport, initialLink: link)
        try await JoinHarness.settle(model)
        let asked = await transport.callCount(for: JoinHarness.policyPath)

        model.linkText = model.linkText

        #expect(model.link?.policyReceipt == "web.mac")
        #expect(model.canJoin)
        // And the relay is not asked all over again for a link that did not change.
        #expect(await transport.callCount(for: JoinHarness.policyPath) == asked)
    }

    /// Replacing an invite to a stranger's relay with one to a community already on this
    /// phone asks that relay nothing — so the terms row has to stop loading, or it sits
    /// there for a question nobody is going to answer.
    @Test func movingToACommunityAlreadyJoinedStopsWaitingOnTerms() async throws {
        let (environment, suite) = JoinHarness.harness("wss://known.example")
        defer { JoinHarness.forget(suite, environment) }
        // Held open, so the first relay is still being asked when the second link arrives —
        // which is the only moment this can go wrong.
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: false), delay: .seconds(30))
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://stranger.example/invite/abc"
        #expect(model.isReadingPolicy)
        model.linkText = "https://known.example/invite/abc"

        #expect(model.alreadyJoined != nil)
        #expect(!model.isReadingPolicy)
    }

    // MARK: - What has to be supplied before joining

    @Test func anAgeAttestationTheRelayRequiresIsTheReadersToMake() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: true))
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)

        #expect(model.policy?.ageAttestationRequired == true)
        #expect(!model.canJoin)
        model.ageConfirmed = true
        #expect(model.canJoin)
    }

    @Test func aPolicyWithNoAttestationDoesNotHoldTheButton() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: false))
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)

        #expect(model.policy != nil)
        #expect(model.canJoin)
    }

    @Test func anExistingKeyHasToBeAKeyBeforeItCanBeUsed() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport(answers: JoinHarness.openRelay))

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)
        model.identity = .existing

        #expect(!model.canJoin)
        model.nsec = "not an nsec"
        #expect(!model.canJoin)
        model.nsec = try PrivateKey().nsec
        #expect(model.canJoin)
    }

    // MARK: - The terms step, and when it is skipped

    /// A handoff from the relay's own web page has already been through the terms, in a
    /// browser, and carries the receipt to prove it. Running the step again would suggest
    /// the first acceptance did not count — and the relay would issue a second receipt
    /// identical to the one already in hand.
    @Test func aLinkCarryingAnAcceptanceSkipsTheTermsStep() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: true))
        let link = try #require(
            InviteLink.parse("buzz://join?relay=wss%3A%2F%2Frelay.example&code=abc&policy_receipt=web.mac")
        )
        let model = JoinHarness.model(environment, transport: transport, initialLink: link)
        try await JoinHarness.settle(model)

        // Not held on an attestation that was made in the browser.
        #expect(model.canJoin)
        await model.submit()

        #expect(await transport.callCount(for: JoinHarness.acceptPath) == 0)
        let claim = try #require(await transport.bodies.last)
        let sent = try #require(try JSONSerialization.jsonObject(with: claim) as? [String: Any])
        #expect(sent["policy_receipt"] as? String == "web.mac")
    }

    @Test func acceptingInAppExchangesTheAttestationForTheReceiptTheClaimCarries() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: true))
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)
        model.ageConfirmed = true
        await model.submit()

        let bodies = await transport.bodies
        #expect(bodies.count == 2)
        let accept = try #require(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect(accept["policy_version"] as? String == "v1")
        #expect(accept["age_confirmed"] as? Bool == true)
        let claim = try #require(try JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(claim["policy_receipt"] as? String == "r.mac")
        #expect(claim["code"] as? String == "abc")
    }

    // MARK: - Refusals

    /// A refused invite must leave nothing behind — no key, no community row, no database —
    /// because the commonest refusal is a link somebody else already used up, and a phone
    /// that collected a dead community from each of those would fill its switcher with
    /// entries that can never connect.
    @Test func anExhaustedInviteAddsNothingToThisPhone() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: [
            JoinHarness.policyPath: [(JoinHarness.data("{}"), 200)],
            JoinHarness.claimPath: [(JoinHarness.data(#"{"error":"invite_exhausted"}"#), 403)],
        ])
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)
        await model.submit()

        #expect(model.error?.contains("already been used") == true)
        #expect(environment.communities.communities.isEmpty)
        #expect(environment.phase == .needsIdentity)
        // Back on the decision, not stuck mid-flight.
        #expect(model.step == .reviewing)
    }

    /// The relay's own wire strings never reach the screen: `invite_expired` tells someone
    /// who cannot mint an invite nothing they can act on.
    @Test func refusalsAreSaidInWordsAReaderCanActOn() {
        #expect(JoinCommunityModel.message(for: .expired).contains("expired"))
        #expect(JoinCommunityModel.message(for: .rateLimited).contains("Wait a minute"))
        #expect(JoinCommunityModel.message(for: .unreachable("x")).contains("Couldn't reach"))
        for error in [InviteError.expired, .exhausted, .invalidCode, .policyRequired, .rateLimited] {
            let message = JoinCommunityModel.message(for: error)
            #expect(!message.contains("invite_"), "wire string leaked: \(message)")
            #expect(!message.contains("_"), "wire string leaked: \(message)")
        }
    }

    /// The read runs before the reader has asked for anything, and the endpoint is the one
    /// part of this flow an older relay simply does not serve. Reporting a failure there
    /// would condemn a join that is about to work.
    @Test func aRelayThatWillNotDiscussItsTermsIsNotAnErrorYet() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(failure: .requestFailed("offline"))
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)

        #expect(model.error == nil)
        #expect(model.policy == nil)
        #expect(model.canJoin)
    }

    // MARK: - A community this phone is already in

    @Test func anInviteToACommunityAlreadyOnThisPhoneOpensItInstead() async throws {
        let (environment, suite) = JoinHarness.harness("wss://relay.example")
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.openRelay)
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"

        #expect(model.alreadyJoined != nil)
        #expect(model.actionTitle == "Open")
        #expect(model.canJoin)
        // Nothing is asked of a relay this phone is already a member of — least of all a
        // use of an invite that may be bounded.
        #expect(await transport.paths.isEmpty)

        await model.submit()
        #expect(environment.communitySheet == nil)
        #expect(await transport.callCount(for: JoinHarness.claimPath) == 0)
    }

    /// The same relay written differently is the same relay: a trailing slash and a
    /// capitalised host are not a second community, and an invite to one you are in must
    /// not create one.
    @Test func matchingAnExistingCommunityIgnoresHowTheRelayWasSpelled() {
        let (environment, suite) = JoinHarness.harness("wss://Relay.Example/")
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport())

        model.linkText = "https://relay.example/invite/abc"

        #expect(model.alreadyJoined != nil)
    }

    // MARK: - Arriving from outside

    @Test func aHandoffURLOpensTheJoinScreenCarryingItsInvite() {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let url = URL(string: "buzz://join?relay=wss%3A%2F%2Frelay.example&code=v2.abc&policy_receipt=r")!

        #expect(environment.handle(incomingURL: url))

        guard case let .join(link) = environment.communitySheet else {
            Issue.record("expected the join sheet, got \(String(describing: environment.communitySheet))")
            return
        }
        #expect(link?.code == "v2.abc")
        #expect(link?.policyReceipt == "r")
    }

    @Test func aURLThatIsNotAnInviteOpensNothing() {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }

        #expect(!environment.handle(incomingURL: URL(string: "buzz://message?channel=a&id=b")!))
        #expect(environment.communitySheet == nil)
    }
}
