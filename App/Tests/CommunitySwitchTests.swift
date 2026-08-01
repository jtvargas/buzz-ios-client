import Foundation
@testable import Hive
import Testing

/// What the composition root does when the reader moves between communities.
///
/// These drive the real ``AppEnvironment`` against a throwaway defaults suite. What they can
/// reach is the part that decides *where the app is*: which community is active, what is
/// persisted, and which screen the phase asks for. What they cannot reach is a started
/// engine — that needs a key in the Keychain and a relay on the other end, and CI has
/// neither — so the switch is exercised here through communities this device has no key
/// for, which is the same path up to the point where a socket would be opened.
@MainActor
@Suite(.serialized)
struct CommunitySwitchTests {
    /// The storage behind a suite. Rebuilt from the suite name rather than handed around,
    /// because `UserDefaults` is the thing being shared here and a second `CommunityStorage`
    /// over the same suite reads exactly what the first one wrote — which is the point of
    /// the assertions that use it.
    private func storage(in suite: String) -> CommunityStorage {
        CommunityStorage(defaults: UserDefaults(suiteName: suite)!)
    }

    /// An environment holding one community per relay, with nothing signed in, and the
    /// defaults suite to throw away afterwards.
    ///
    /// The list is written *before* the environment is built so the legacy adoption never
    /// runs: it only fires on an empty directory, and this machine's simulator may well have
    /// a real key under the old account.
    private func harness(_ relays: String...) -> (AppEnvironment, String) {
        let suite = "hive.tests.switch.\(UUID().uuidString)"
        var directory = CommunityDirectory()
        for relay in relays { directory.add(Community.new(relayURLString: relay)) }
        storage(in: suite).save(directory)
        return (AppEnvironment(communityStorage: storage(in: suite)), suite)
    }

    private func forget(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func launchesIntoTheCommunityItLeftOffIn() {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        #expect(environment.communities.communities.count == 2)
        // No key for it, so the gate — but the *relay* is already mirrored, which is what
        // names the community over the gate and prefills the field.
        #expect(environment.phase == .needsIdentity)
        #expect(RelayEndpoint.storedURLString == "wss://a.example")
    }

    @Test func switchingMovesTheReaderAndWritesItDown() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        let storage = storage(in: suite)
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let target = environment.communities.communities[1].id

        await environment.switchCommunity(to: target)

        #expect(environment.communities.activeID == target)
        // Durable before anything else happens: a crash mid-switch has to relaunch into the
        // community the reader chose, not the one they left.
        #expect(storage.load().activeID == target)
        #expect(RelayEndpoint.storedURLString == "wss://b.example")
        // Signed out of this one, so the gate rather than a workspace it cannot authenticate
        // for. Nothing of the outgoing community is left running.
        #expect(environment.phase == .needsIdentity)
        #expect(environment.engine == nil)
        #expect(environment.store == nil)
        #expect(environment.selfPubkeyHex == nil)
    }

    @Test func switchingToTheCommunityAlreadyOpenChangesNothing() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let active = environment.communities.activeID
        await environment.switchCommunity(to: active!)
        #expect(environment.communities.activeID == active)
    }

    @Test func aStaleRowCannotSwitchToACommunityThatIsGone() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example")
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let active = environment.communities.activeID
        await environment.switchCommunity(to: UUID())
        #expect(environment.communities.activeID == active)
        #expect(RelayEndpoint.storedURLString == "wss://a.example")
    }

    @Test func renamingIsRememberedAcrossLaunches() {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example")
        let storage = storage(in: suite)
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        environment.renameCommunity(environment.communities.communities[0].id, to: "Work")
        #expect(storage.load().communities.map(\.name) == ["Work"])
    }

    @Test func removingAnotherCommunityLeavesTheReaderWhereTheyAre() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        let storage = storage(in: suite)
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let active = environment.communities.activeID
        let other = environment.communities.communities[1].id

        await environment.removeCommunity(other)

        #expect(environment.communities.communities.count == 1)
        #expect(environment.communities.activeID == active)
        #expect(storage.load().communities.count == 1)
        #expect(RelayEndpoint.storedURLString == "wss://a.example")
    }

    @Test func removingTheLastCommunityLeavesOnboarding() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example")
        let storage = storage(in: suite)
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        await environment.removeCommunity(environment.communities.communities[0].id)
        #expect(environment.communities.isEmpty)
        #expect(storage.load().isEmpty)
        #expect(environment.phase == .needsIdentity)
    }

    @Test func removingTheActiveCommunityHandsOverToTheNextOne() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let first = environment.communities.communities[0].id
        let second = environment.communities.communities[1].id

        await environment.removeCommunity(first)

        #expect(environment.communities.activeID == second)
        // The heading has to be the community now being opened, from the first frame.
        #expect(RelayEndpoint.storedURLString == "wss://b.example")
    }

    // MARK: - Going back, and going nowhere twice at once

    @Test func goingToAnotherCommunityAndBackKeepsEachOneItsOwnStorage() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        let storage = storage(in: suite)
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let first = environment.communities.communities[0]
        let second = environment.communities.communities[1]
        // The premise of the whole feature: no two communities can name each other's key or
        // each other's database.
        #expect(first.keychainAccount != second.keychainAccount)
        #expect(first.storeFilename != second.storeFilename)

        await environment.switchCommunity(to: second.id)
        #expect(RelayEndpoint.storedURLString == "wss://b.example")
        await environment.switchCommunity(to: first.id)

        #expect(environment.communities.activeID == first.id)
        #expect(RelayEndpoint.storedURLString == "wss://a.example")
        // A round trip is not a re-add: coming back finds the record that was already here,
        // pointing at the same key and the same history, in the same order in the list.
        #expect(environment.communities.communities.map(\.id) == [first.id, second.id])
        #expect(
            environment.communities.communities.map(\.storeFilename)
                == [first.storeFilename, second.storeFilename]
        )
        #expect(storage.load().activeID == first.id)
    }

    /// Two transitions asked for at once must not interleave.
    ///
    /// This is the one property the state assertions above cannot show, because a community
    /// with no key never builds a graph — so a doubled teardown/start is invisible to them.
    /// It is asserted where it is decided instead: nothing may run between another
    /// transition's first and last step.
    @Test func aTransitionWaitsForTheOneBeforeIt() async {
        let (environment, suite) = harness("wss://a.example")
        defer { forget(suite) }
        let transcript = TransitionTranscript()

        async let first: Void = environment.serialisingTransitions {
            transcript.record("first in")
            // Suspends without finishing — the moment a second transition would otherwise
            // run inside this one. Two hops, because one is what a single `await` inside a
            // teardown costs and the real ones are far longer than that.
            await Task.yield()
            await Task.yield()
            transcript.record("first out")
        }
        async let second: Void = environment.serialisingTransitions {
            transcript.record("second in")
            await Task.yield()
            transcript.record("second out")
        }
        _ = await (first, second)

        // Whichever went first, neither is inside the other.
        #expect(
            transcript.entries == ["first in", "first out", "second in", "second out"]
                || transcript.entries == ["second in", "second out", "first in", "first out"]
        )
    }

    // MARK: - The frame that must never be drawn

    /// The one visible failure this feature can have: community A's conversations on screen
    /// under community B's name.
    ///
    /// ``AppEnvironment/workspaceMatchesActiveCommunity`` is what refuses it, and it is
    /// asserted as a decision over its four inputs rather than through a switch, because the
    /// mismatched state it exists for is one a test cannot otherwise stand in: reaching it
    /// through the real path means a *started* session, and that needs a key in the Keychain
    /// and a relay on the other end.
    @Test func aGraphBelongingToAnotherCommunityIsNotTheWorkspace() {
        let reading = Community.ID()
        let left = Community.ID()

        // The frame in question: a graph is up, and it is the community being left.
        #expect(
            AppEnvironment.workspaceMatchesActiveCommunity(
                sessionCommunityID: left,
                activeCommunityID: reading,
                hasEngine: true,
                hasStore: true
            ) == false
        )
        // The same community: the ordinary case, and the only one that draws.
        #expect(
            AppEnvironment.workspaceMatchesActiveCommunity(
                sessionCommunityID: reading,
                activeCommunityID: reading,
                hasEngine: true,
                hasStore: true
            )
        )
    }

    /// Half a graph is not a workspace either. Both halves are dropped together by
    /// ``AppEnvironment/teardownSession()``, so neither of these is reachable today — they
    /// are asserted because the gate is what the drawing depends on, and a gate that answers
    /// yes to a missing store would hand ``RootView`` a `nil` to unwrap.
    @Test(arguments: [(false, true), (true, false), (false, false)])
    func anIncompleteGraphIsNotTheWorkspace(hasEngine: Bool, hasStore: Bool) {
        let reading = Community.ID()
        #expect(
            AppEnvironment.workspaceMatchesActiveCommunity(
                sessionCommunityID: reading,
                activeCommunityID: reading,
                hasEngine: hasEngine,
                hasStore: hasStore
            ) == false
        )
    }

    /// No session and no community are each a "no" on their own — an unset id must never
    /// match an unset id, which is the shape a plain `==` would have got wrong.
    @Test func nothingMountedIsNeverAMatch() {
        #expect(
            AppEnvironment.workspaceMatchesActiveCommunity(
                sessionCommunityID: nil,
                activeCommunityID: nil,
                hasEngine: true,
                hasStore: true
            ) == false
        )
        #expect(
            AppEnvironment.workspaceMatchesActiveCommunity(
                sessionCommunityID: nil,
                activeCommunityID: Community.ID(),
                hasEngine: true,
                hasStore: true
            ) == false
        )
    }

    /// And the property the view actually reads is wired to that decision: an environment
    /// with a community chosen but nothing signed in has no graph, so it draws no workspace.
    @Test func anEnvironmentWithNoSessionDrawsNoWorkspace() {
        let (environment, suite) = harness("wss://a.example")
        defer { forget(suite) }
        #expect(environment.sessionCommunityID == nil)
        #expect(environment.communities.activeID != nil)
        #expect(environment.workspaceMatchesActiveCommunity == false)
    }

    @Test func signingOutKeepsTheCommunitiesAndTheirHistories() async {
        let previousRelay = RelayEndpoint.storedURLString
        let (environment, suite) = harness("wss://a.example", "wss://b.example")
        let storage = storage(in: suite)
        defer {
            forget(suite)
            RelayEndpoint.storedURLString = previousRelay
        }
        let filenames = environment.communities.communities.map(\.storeFilename)

        _ = await environment.signOut()

        #expect(environment.phase == .needsIdentity)
        // Records and databases survive: the recorded owner decides at the next sign-in, so
        // a same-key return still finds its own history (§ StoreOwnership).
        #expect(storage.load().communities.map(\.storeFilename) == filenames)
    }
}

/// What ran, in the order it ran, for ``CommunitySwitchTests/aTransitionWaitsForTheOneBeforeIt()``.
///
/// Main-actor isolated rather than locked: the transitions it records are, so a lock would
/// protect it from nothing that can happen here.
@MainActor
final class TransitionTranscript {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}
