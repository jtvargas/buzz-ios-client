import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// A relay that answers from a script and remembers what it was asked.
private actor ScriptedTransport: InviteTransport {
    private(set) var paths: [String] = []
    private(set) var bodies: [Data] = []
    private var answers: [String: [(Data, Int)]]
    private let failure: TransportError?

    /// - Parameter answers: keyed by the request path, so a test names only the calls it
    ///   is about. An unscripted path answers 500, which every caller reads as a failure.
    init(answers: [String: [(Data, Int)]] = [:], failure: TransportError? = nil) {
        self.answers = answers
        self.failure = failure
    }

    func get(from url: URL, headers _: [String: String]) async throws -> (Data, Int) {
        try record(url, body: nil)
    }

    func post(body: Data, to url: URL, headers _: [String: String]) async throws -> (Data, Int) {
        try record(url, body: body)
    }

    private func record(_ url: URL, body: Data?) throws -> (Data, Int) {
        paths.append(url.path())
        if let body { bodies.append(body) }
        if let failure { throw failure }
        guard var queued = answers[url.path()], !queued.isEmpty else { return (Data(), 500) }
        let answer = queued.removeFirst()
        answers[url.path()] = queued
        return answer
    }

    func callCount(for path: String) -> Int { paths.filter { $0 == path }.count }
}

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
/// is why ``forget(_:_:)`` has a second half.
@MainActor
@Suite(.serialized)
struct JoinCommunityModelTests {
    // MARK: - Harness

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    private static let policyPath = "/api/join-policy"
    private static let acceptPath = "/api/invites/accept-policy"
    private static let claimPath = "/api/invites/claim"

    private static let openRelay: [String: [(Data, Int)]] = [policyPath: [(data("{}"), 200)]]

    private static func policedRelay(ageRequired: Bool) -> [String: [(Data, Int)]] {
        [
            policyPath: [(data("""
            {"policy":{"terms_markdown":"# Terms","privacy_markdown":"# Privacy",
             "age_attestation_required":\(ageRequired),"version":"v1"}}
            """), 200)],
            acceptPath: [(data(#"{"receipt":"r.mac"}"#), 200)],
            claimPath: [(data(#"{"status":"joined","community_id":"c","host":"h","role":"member"}"#), 200)],
        ]
    }

    /// An environment with one community per relay and nothing signed in, plus the defaults
    /// suite to throw away. Written before the environment is built so legacy adoption —
    /// which fires only on an empty directory — never runs against this machine's Keychain.
    private func harness(_ relays: String...) -> (AppEnvironment, String) {
        let suite = "hive.tests.join.\(UUID().uuidString)"
        let storage = CommunityStorage(defaults: UserDefaults(suiteName: suite)!)
        var directory = CommunityDirectory()
        for relay in relays { directory.add(Community.new(relayURLString: relay)) }
        storage.save(directory)
        return (AppEnvironment(communityStorage: storage), suite)
    }

    /// Throws away everything a run created.
    ///
    /// The defaults suite is the obvious half. The other half is that a join which gets past
    /// the claim goes on to do the real thing — a key in the Keychain, a database on disk —
    /// and those outlive the suite: the Keychain account is named after a fresh UUID, so
    /// without this every successful-path run leaves one behind for ever.
    private func forget(_ suite: String, _ environment: AppEnvironment? = nil) {
        for community in environment?.communities.communities ?? [] {
            try? KeychainSigner(account: community.keychainAccount).delete()
            AppEnvironment.deleteStore(filename: community.storeFilename)
        }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func model(
        _ environment: AppEnvironment,
        transport: ScriptedTransport,
        initialLink: InviteLink? = nil
    ) -> JoinCommunityModel {
        JoinCommunityModel(environment: environment, initialLink: initialLink) { relay in
            InviteClient(relayURLString: relay, transport: transport)
        }
    }

    /// Waits for the background policy read to land. It runs off the reader's path
    /// deliberately, so there is nothing to await — the screen simply fills in.
    private func settle(_ model: JoinCommunityModel) async throws {
        for _ in 0 ..< 200 {
            if !model.isReadingPolicy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the join policy never resolved")
    }

    // MARK: - Reading the link

    @Test func aLinkThatIsNotAnInviteLeavesTheScreenWaiting() {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let model = model(environment, transport: ScriptedTransport())

        model.linkText = "https://relay.example/channels/abc"

        #expect(model.step == .needsLink)
        #expect(model.link == nil)
        #expect(!model.canJoin)
        // Not an error: a half-typed link is the normal state of a text field, and calling
        // it wrong on every keystroke is how a form shouts at someone who is doing fine.
        #expect(model.error == nil)
    }

    @Test func anInviteLinkNamesTheRelayItWillJoin() async throws {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: Self.openRelay)
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/v2.abc"
        try await settle(model)

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
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: [Self.policyPath: [
            (Self.data("{}"), 200), (Self.data("{}"), 200),
        ]])
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)
        model.linkText = "https://relay.example/invite/abc "
        try await settle(model)

        #expect(await transport.callCount(for: Self.policyPath) == 1)
    }

    // MARK: - What has to be supplied before joining

    @Test func anAgeAttestationTheRelayRequiresIsTheReadersToMake() async throws {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: Self.policedRelay(ageRequired: true))
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)

        #expect(model.policy?.ageAttestationRequired == true)
        #expect(!model.canJoin)
        model.ageConfirmed = true
        #expect(model.canJoin)
    }

    @Test func aPolicyWithNoAttestationDoesNotHoldTheButton() async throws {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: Self.policedRelay(ageRequired: false))
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)

        #expect(model.policy != nil)
        #expect(model.canJoin)
    }

    @Test func anExistingKeyHasToBeAKeyBeforeItCanBeUsed() async throws {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let model = model(environment, transport: ScriptedTransport(answers: Self.openRelay))

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)
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
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: Self.policedRelay(ageRequired: true))
        let link = try #require(
            InviteLink.parse("buzz://join?relay=wss%3A%2F%2Frelay.example&code=abc&policy_receipt=web.mac")
        )
        let model = model(environment, transport: transport, initialLink: link)
        try await settle(model)

        // Not held on an attestation that was made in the browser.
        #expect(model.canJoin)
        await model.submit()

        #expect(await transport.callCount(for: Self.acceptPath) == 0)
        let claim = try #require(await transport.bodies.last)
        let sent = try #require(try JSONSerialization.jsonObject(with: claim) as? [String: Any])
        #expect(sent["policy_receipt"] as? String == "web.mac")
    }

    @Test func acceptingInAppExchangesTheAttestationForTheReceiptTheClaimCarries() async throws {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: Self.policedRelay(ageRequired: true))
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)
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
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: [
            Self.policyPath: [(Self.data("{}"), 200)],
            Self.claimPath: [(Self.data(#"{"error":"invite_exhausted"}"#), 403)],
        ])
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)
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
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(failure: .requestFailed("offline"))
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"
        try await settle(model)

        #expect(model.error == nil)
        #expect(model.policy == nil)
        #expect(model.canJoin)
    }

    // MARK: - A community this phone is already in

    @Test func anInviteToACommunityAlreadyOnThisPhoneOpensItInstead() async throws {
        let (environment, suite) = harness("wss://relay.example")
        defer { forget(suite, environment) }
        let transport = ScriptedTransport(answers: Self.openRelay)
        let model = model(environment, transport: transport)

        model.linkText = "https://relay.example/invite/abc"

        #expect(model.alreadyJoined != nil)
        #expect(model.actionTitle == "Open")
        #expect(model.canJoin)
        // Nothing is asked of a relay this phone is already a member of — least of all a
        // use of an invite that may be bounded.
        #expect(await transport.paths.isEmpty)

        await model.submit()
        #expect(environment.communitySheet == nil)
        #expect(await transport.callCount(for: Self.claimPath) == 0)
    }

    /// The same relay written differently is the same relay: a trailing slash and a
    /// capitalised host are not a second community, and an invite to one you are in must
    /// not create one.
    @Test func matchingAnExistingCommunityIgnoresHowTheRelayWasSpelled() {
        let (environment, suite) = harness("wss://Relay.Example/")
        defer { forget(suite, environment) }
        let model = model(environment, transport: ScriptedTransport())

        model.linkText = "https://relay.example/invite/abc"

        #expect(model.alreadyJoined != nil)
    }

    // MARK: - Arriving from outside

    @Test func aHandoffURLOpensTheJoinScreenCarryingItsInvite() {
        let (environment, suite) = harness()
        defer { forget(suite, environment) }
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
        let (environment, suite) = harness()
        defer { forget(suite, environment) }

        #expect(!environment.handle(incomingURL: URL(string: "buzz://message?channel=a&id=b")!))
        #expect(environment.communitySheet == nil)
    }
}
