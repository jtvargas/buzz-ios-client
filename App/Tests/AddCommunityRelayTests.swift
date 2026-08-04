import BuzzKit
import Foundation
@testable import Hive
import Testing

/// What "Add a relay" will take, and what it says when it will not.
///
/// Two defects, one shape. The first was never in ``RelayEndpoint``: its converter has taken
/// an `https://` address all along (`RelayEndpointTests.normalisesAnyRelayForm`) — the screen
/// asked a *different* question, `websocketURL(from:)`, which takes sockets only, so a relay
/// copied out of a browser's address bar left every button disabled with nothing saying why.
///
/// The second was the opposite failure on the same field: an **invite link** pasted into it
/// was accepted as a relay address, path and all, so Hive opened a websocket to a web page and
/// sat there. Reported as "it never reached the relay to get the channels", which is exactly
/// what that looks like from outside.
///
/// Both are now read by one rule (§ ``CommunityAddress``), so these assert that rule and the
/// identity paths behind it rather than the converter they all end up in.
@MainActor
@Suite(.serialized)
struct AddCommunityRelayTests {
    // MARK: - The rule the screen asks

    @Test func theRelayFieldTakesBothFormsARelayIsWrittenIn() {
        #expect(CommunityAddress("wss://tech.communities.buzz.xyz") == .relay("wss://tech.communities.buzz.xyz"))
        // The `https` spelling is taken *and reduced*: what comes back is the socket form,
        // because that is what identifies a community.
        #expect(CommunityAddress("https://tech.communities.buzz.xyz") == .relay("wss://tech.communities.buzz.xyz"))
        #expect(CommunityAddress("ws://10.0.0.2:3004") == .relay("ws://10.0.0.2:3004"))
        #expect(CommunityAddress("http://10.0.0.2:3004") == .relay("ws://10.0.0.2:3004"))
        // The rule the screen used to ask, on the same address, so the disagreement that
        // produced a permanently disabled button is written down rather than remembered.
        #expect(RelayEndpoint.websocketURL(from: "https://tech.communities.buzz.xyz") == nil)
    }

    @Test func textThatDoesNotNameARelayIsStillRefused() {
        #expect(CommunityAddress("") == .nothingYet)
        // No scheme: a bare host is ambiguous about how to reach it, and guessing is how a
        // client silently downgrades somebody's connection.
        #expect(CommunityAddress("tech.communities.buzz.xyz") == .unusable(.notAnAddress))
        #expect(CommunityAddress("ftp://relay.example") == .unusable(.notAnAddress))
    }

    /// The reported bug, from the failing side: this text used to reduce to a relay whose
    /// address had a **web page** on the end of it, and the screen connected to it.
    @Test func anInviteLinkInTheRelayFieldIsReadAsAnInvitation() throws {
        let pasted = "https://buzzdir.communities.buzz.xyz/invite/v2.umQGOlbNHvzs5fDVgxWCcU1N6ZmKr_3QAqPiuM4AgV4"

        guard case let .invitation(link) = CommunityAddress(pasted) else {
            Issue.record("An invite link in the relay field must be read as an invitation")
            return
        }
        #expect(link.relayURLString == "wss://buzzdir.communities.buzz.xyz")
        #expect(link.code == "v2.umQGOlbNHvzs5fDVgxWCcU1N6ZmKr_3QAqPiuM4AgV4")

        // What the old rule did with the very same text: a socket URL pointing at a page.
        let asARelay = try #require(RelayEndpoint.websocketURLString(fromAnyRelay: pasted))
        #expect(asARelay.hasSuffix("/invite/v2.umQGOlbNHvzs5fDVgxWCcU1N6ZmKr_3QAqPiuM4AgV4"))
    }

    /// The socket spelling of the same link — the one that was actually pasted first. It is
    /// unambiguous, because a websocket origin has no `/invite/<code>` under it.
    @Test func aSocketSpellingOfAnInviteIsAnInvitationToo() {
        guard case let .invitation(link) = CommunityAddress("wss://buzzdir.communities.buzz.xyz/invite/v2.abc") else {
            Issue.record("wss://…/invite/<code> must be read as an invitation")
            return
        }
        #expect(link.relayURLString == "wss://buzzdir.communities.buzz.xyz")
        #expect(link.code == "v2.abc")
    }

    /// A URL with a page under it that is *not* an invite is refused rather than connected to.
    @Test func aRelayAddressWithAPageUnderItIsRefused() {
        #expect(CommunityAddress("https://buzzdir.communities.buzz.xyz/channels") == .unusable(.hasAPageUnderIt))
        #expect(CommunityAddress("wss://relay.example/?token=1") == .unusable(.hasAPageUnderIt))
        // A trailing slash is the same origin, not a page, and is reduced away.
        #expect(CommunityAddress("https://relay.example/") == .relay("wss://relay.example"))
    }

    /// Every state of the field says something, and each says something different. The dead
    /// end being fixed is a control that refuses without a next thing to try.
    @Test func theRefusalNamesAWayForward() {
        #expect(OnboardingView.relayRefusedNote.contains("wss://"))
        #expect(OnboardingView.relayRefusedNote.contains("https://"))
        #expect(OnboardingView.relayHasAPageNote.contains("just"))
        #expect(OnboardingView.inviteNote.contains("invite link"))
        #expect(OnboardingView.relayHasAPageNote != OnboardingView.relayRefusedNote)
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

    // MARK: - The door the communities list opens

    /// The communities list opens ``AppEnvironment/CommunitySheet/scan`` rather than
    /// ``AppEnvironment/CommunitySheet/add``, and the two have to stay *different* sheets by
    /// `Identifiable`: `.sheet(item:)` re-presents only when the id changes, so a `.scan`
    /// that answered `"add"` would leave whichever screen was already up in place — the hub
    /// where the scanner was asked for, or the scanner where the hub was.
    @Test func theScannerAndTheHubAreDifferentSheets() {
        #expect(AppEnvironment.CommunitySheet.scan.id == "scan")
        #expect(AppEnvironment.CommunitySheet.scan.id != AppEnvironment.CommunitySheet.add.id)
        #expect(AppEnvironment.CommunitySheet.scan != .add)
    }
}
