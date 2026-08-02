import BuzzKit
@testable import Hive
import Testing

/// What the join screen *says* — the half of it that exists because two different controls
/// were reported as "it stays disabled".
///
/// Split from ``JoinCommunityModelTests`` along the same seam the source is split on
/// (``JoinCommunityGuidance``): nothing here decides anything, and every assertion is about a
/// sentence a reader can act on. The decisions themselves are next door.
@MainActor
@Suite(.serialized)
struct JoinCommunityGuidanceTests {
    // MARK: - Under the field

    /// The near miss this screen is actually pasted: a relay address. It is a URL, it names
    /// the right host, and it is what somebody told "the community is at X" reaches for —
    /// and before this it produced nothing at all: no destination, no error, a Join button
    /// that stayed grey. The note is the only thing on screen that can explain that.
    @Test func aRelayAddressIsNamedRatherThanIgnored() {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport())

        model.linkText = "https://tech.communities.buzz.xyz"

        #expect(model.link == nil)
        #expect(!model.canJoin)
        #expect(model.linkNote == JoinCommunityModel.relayNotInviteNote)
        // Still not an error: nothing has failed, and this text field is where a mistake
        // is meant to be made.
        #expect(model.error == nil)
    }

    @Test func anEmptyFieldSaysWhatTheScreenIsFor() {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport())

        #expect(model.linkNote == JoinCommunityModel.blurb)

        model.linkText = "https://relay.example/channels/abc"
        #expect(model.linkNote == JoinCommunityModel.notAnInviteNote)

        model.linkText = "   "
        #expect(model.linkNote == JoinCommunityModel.blurb)
    }

    @Test func aResolvedInviteStopsExplainingItself() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport(answers: JoinHarness.openRelay))

        model.linkText = "https://relay.example/invite/v2.abc"
        try await JoinHarness.settle(model)

        #expect(model.linkNote == JoinCommunityModel.blurb)
    }

    // MARK: - Under the button

    /// The reported bug, from the reader's side: the button was grey and the screen said
    /// nothing about it, on a relay that does require an attestation. Every state of that
    /// button now names the control that answers it.
    @Test func aGreyJoinButtonSaysWhatItIsWaitingFor() async throws {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let transport = ScriptedTransport(answers: JoinHarness.policedRelay(ageRequired: true))
        let model = JoinHarness.model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await JoinHarness.settle(model)

        #expect(model.blocked == .needsAgeAttestation)
        #expect(model.blockedNote?.contains("age") == true)
        model.ageConfirmed = true
        #expect(model.blocked == nil)
        #expect(model.blockedNote == nil)

        // And the other control on the screen that can hold it.
        model.identity = .existing
        #expect(model.blocked == .needsValidKey)
        #expect(model.blockedNote?.contains("nsec1") == true)
    }

    /// An empty field is not a refusal, and the footer under it is already saying what to do
    /// — a second sentence under the button would be the same instruction twice.
    @Test func anEmptyFieldDoesNotAlsoAccuseTheButton() {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }
        let model = JoinHarness.model(environment, transport: ScriptedTransport())

        #expect(model.blocked == .needsLink)
        #expect(model.blockedNote == nil)
    }

    // MARK: - When the relay refuses

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
}
