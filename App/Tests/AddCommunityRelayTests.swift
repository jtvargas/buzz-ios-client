import Foundation
@testable import Hive
import Testing

/// What "Add a relay" will take, and what it says when it will not.
///
/// The defect these exist for was never in ``RelayEndpoint``: its converter has taken an
/// `https://` address all along (`RelayEndpointTests.normalisesAnyRelayForm`). It was that
/// the screen asked a *different* question — `websocketURL(from:)`, which takes sockets only
/// — so a relay copied out of a browser's address bar left every button on the screen
/// disabled with nothing saying why. A dead control that will not explain itself is worse
/// than a refusal, because there is no next thing to try.
///
/// So these assert the rule the screen asks and the two identity paths behind it, rather
/// than the converter they all end up in.
@MainActor
@Suite(.serialized)
struct AddCommunityRelayTests {
    // MARK: - The rule the screen asks

    @Test func theRelayFieldTakesBothFormsARelayIsWrittenIn() {
        #expect(OnboardingView.relayIsUsable("wss://tech.communities.buzz.xyz"))
        #expect(OnboardingView.relayIsUsable("https://tech.communities.buzz.xyz"))
        #expect(OnboardingView.relayIsUsable("ws://10.0.0.2:3004"))
        #expect(OnboardingView.relayIsUsable("http://10.0.0.2:3004"))
        // The rule the screen used to ask, on the same address, so the disagreement that
        // produced a permanently disabled button is written down rather than remembered.
        #expect(RelayEndpoint.websocketURL(from: "https://tech.communities.buzz.xyz") == nil)
    }

    @Test func textThatDoesNotNameARelayIsStillRefused() {
        #expect(!OnboardingView.relayIsUsable(""))
        // No scheme: a bare host is ambiguous about how to reach it, and guessing is how a
        // client silently downgrades somebody's connection.
        #expect(!OnboardingView.relayIsUsable("tech.communities.buzz.xyz"))
        #expect(!OnboardingView.relayIsUsable("ftp://relay.example"))
    }

    /// The note under a refused field names both forms that work. Asserted because the whole
    /// point of this change is that the reader is told what to type next.
    @Test func theRefusalNamesAWayForward() {
        #expect(OnboardingView.relayRefusedNote.contains("wss://"))
        #expect(OnboardingView.relayRefusedNote.contains("https://"))
        #expect(IdentityGateError.invalidRelayURL.message.contains("wss://"))
    }

    // MARK: - The identity paths behind it

    /// An `https` relay reaches the key rather than being turned away at the relay check: a
    /// bad secret has to be reported as a bad secret. This is the assertion that goes red
    /// without the fix — it answered `.invalidRelayURL` before.
    @Test func pastingAKeyAgainstAnHTTPSRelayGetsPastTheRelayCheck() async {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }

        let result = await environment.submitIdentity(
            relayURLString: "https://relay.example",
            nsec: "not-an-nsec"
        )

        #expect(result == .invalidSecretKey)
    }

    @Test func textThatIsNotARelayIsStillReportedAsOne() async {
        let (environment, suite) = JoinHarness.harness()
        defer { JoinHarness.forget(suite, environment) }

        let result = await environment.submitIdentity(
            relayURLString: "relay.example",
            nsec: "not-an-nsec"
        )

        #expect(result == .invalidRelayURL)
    }

    /// Why the normalising happens before the community is looked up rather than at the
    /// field: a community is identified by its *socket* form, and the raw `https` string
    /// identifies nothing at all. Reaching ``AppEnvironment/joinCommunity(relayURLString:key:)``
    /// with the unreduced text would file the relay somebody already has as a second
    /// community, with its own key and its own copy of the same history.
    @Test func bothFormsNameOneCommunity() throws {
        let reduced = try #require(RelayEndpoint.websocketURLString(fromAnyRelay: "https://relay.example"))

        #expect(Community.new(relayURLString: reduced).isSameRelay(as: "wss://relay.example"))
        #expect(Community.relayIdentity(of: "https://relay.example") == nil)
    }
}
