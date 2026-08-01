import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// A relay that answers from a script and remembers what it was asked.
actor ScriptedTransport: InviteTransport {
    private(set) var paths: [String] = []
    private(set) var bodies: [Data] = []
    private var answers: [String: [(Data, Int)]]
    private let failure: TransportError?
    private let delay: Duration?

    /// - Parameters:
    ///   - answers: keyed by the request path, so a test names only the calls it is about.
    ///     An unscripted path answers 500, which every caller reads as a failure.
    ///   - delay: how long to hold a request open before answering. A test that is about
    ///     what the screen looks like *while* the relay is being asked needs a request that
    ///     is still in flight, which an instant answer cannot give it.
    init(
        answers: [String: [(Data, Int)]] = [:],
        failure: TransportError? = nil,
        delay: Duration? = nil
    ) {
        self.answers = answers
        self.failure = failure
        self.delay = delay
    }

    func get(from url: URL, headers _: [String: String]) async throws -> (Data, Int) {
        let answer = try record(url, body: nil)
        if let delay { try await Task.sleep(for: delay) }
        return answer
    }

    func post(body: Data, to url: URL, headers _: [String: String]) async throws -> (Data, Int) {
        let answer = try record(url, body: body)
        if let delay { try await Task.sleep(for: delay) }
        return answer
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

/// The relay scripts and the throwaway environment ``JoinCommunityModelTests`` drives.
///
/// Beside the suite rather than inside it, so that file stays about the decisions being
/// asserted rather than about the fixtures they are asserted against.
@MainActor
enum JoinHarness {
    static func data(_ text: String) -> Data { Data(text.utf8) }

    static let policyPath = "/api/join-policy"
    static let acceptPath = "/api/invites/accept-policy"
    static let claimPath = "/api/invites/claim"

    static let openRelay: [String: [(Data, Int)]] = [policyPath: [(data("{}"), 200)]]

    static func policedRelay(ageRequired: Bool) -> [String: [(Data, Int)]] {
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
    static func harness(_ relays: String...) -> (AppEnvironment, String) {
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
    static func forget(_ suite: String, _ environment: AppEnvironment? = nil) {
        for community in environment?.communities.communities ?? [] {
            try? KeychainSigner(account: community.keychainAccount).delete()
            AppEnvironment.deleteStore(filename: community.storeFilename)
        }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    static func model(
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
    static func settle(_ model: JoinCommunityModel) async throws {
        for _ in 0 ..< 200 {
            if !model.isReadingPolicy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the join policy never resolved")
    }
}
