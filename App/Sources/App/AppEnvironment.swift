import BuzzKit
import Foundation
import NostrCore
import SwiftUI

/// The composition root: one `@MainActor @Observable` object, created once in
/// ``HiveApp`` as `@State` and injected down with `.environment(_:)`.
///
/// It builds the production object graph the engine's injectable init was made for
/// — `BuzzEventStore`, `KeychainSigner`, `RelayConnection`, `SubscriptionManager`,
/// `PresenceStore`, `WindowClient`, `SyncEngine` — and owns the launch identity
/// gate and the live engine-state pill's source. Nothing here reaches the socket
/// directly; the engine does (the BuzzKit boundary rule).
///
/// # One graph at a time, and it belongs to a community
///
/// Everything from ``store`` down is built *for the active community* and dropped when
/// another one is opened (§ ``switchCommunity(to:)``). That is why those properties are
/// `var` and optional where they used to be `let`: a community is a relay, an identity and
/// a database, and none of the three can be swapped while a graph built on the previous
/// three is still running.
///
/// Desktop reaches the same conclusion from the other end. It remounts its whole
/// community-scoped subtree on a key and then explicitly resets fourteen module-level
/// caches, because a remount clears component state and not module state
/// (`buzz/AGENTS.md` § Community Switching). Hive's equivalent of that list is short by
/// construction — the per-community state *is* this object graph, and ``RootView`` keys the
/// tree on the community id so no view or model outlives the switch — but the rule is the
/// same one: anything holding community-scoped data must be named in ``teardownSession()``
/// or it leaks into the next community.
@MainActor
@Observable
final class AppEnvironment {
    /// What the root view should present.
    enum Phase: Equatable {
        /// No identity is stored for the active community (or there is no community at
        /// all) — show the gate.
        case needsIdentity
        /// A known identity is being composed into an engine. Ends when the engine
        /// *exists*, not when it has connected — deliberately not a network wait. Draws the
        /// sidebar's own waiting state, so the launch reads as one surface filling in
        /// rather than a spinner handing over to a screen. A community switch passes
        /// through here too, which is what keeps the outgoing community's rows off screen
        /// under the incoming community's name.
        case bootstrapping
        /// An identity is loaded and the engine started — show the app.
        case running
        /// Launch failed in a way the user cannot resolve in-app (e.g. the store
        /// could not be opened). Rare; surfaced rather than crashed.
        case failed(String)
    }

    private(set) var phase: Phase
    /// The engine's lifecycle, mirrored for the toolbar pill. Seeded `.stopped`
    /// and updated from ``SyncEngine/states()``.
    private(set) var engineState: SyncEngine.State = .stopped
    /// Whether this session has ever reached ``SyncEngine/State/running``.
    ///
    /// The one fact that separates *connecting* from *reconnecting*, which the engine
    /// state cannot carry on its own — both are ``SyncEngine/State/starting``. Held
    /// here rather than in the surface that draws the word, because a conversation
    /// opened mid-reconnect has itself never seen a live engine and would otherwise
    /// call a dropped connection a cold start. Reset with the engine on sign-out, and on a
    /// community switch: the community being opened has not connected before either.
    private(set) var hasConnectedBefore = false
    /// The authority behind the currently mounted channel list. On retry this
    /// moves through `.checking` without unmounting the workspace.
    private(set) var channelDirectoryStatus: ChannelDirectoryStatus = .checking

    /// Every community on this device, and which one is being read.
    private(set) var communities: CommunityDirectory
    let communityStorage: CommunityStorage
    /// Which community sheet is up, or `nil` for none.
    ///
    /// Held here, and presented by ``RootView``, because both sheets outlive the surface
    /// that opens them: the workspace below is remounted the moment a switch begins
    /// (``RootView`` keys it on the active community), so a sheet owned by the sidebar would
    /// be torn off mid-flow — taking a half-finished pairing, or the error explaining why a
    /// community could not be opened, with it.
    var communitySheet: CommunitySheet?
    /// Whether the app's settings are up.
    ///
    /// Deliberately *not* a `CommunitySheet` case. That type is documented as the doors onto
    /// the community list, and everything on it is about one community; these preferences are
    /// the opposite — they are what holds whichever community is open. Presented from the same
    /// place for the same reason, though: it is opened from the workspace panel, which closes
    /// itself on the way, so a sheet owned down there would be presented by a view that is
    /// already sliding off.
    var showsSettings = false
    /// Something the app has to say that no surface is left standing to say itself.
    ///
    /// A join that fails, or a key that would not delete, both end with the workspace
    /// remounted or replaced — so the sheet or the screen that would have reported it is
    /// gone by the time there is anything to report. ``RootView`` draws this, above the
    /// remount boundary, which is the one place that survives both.
    var notice: AppNotice?

    /// One thing the app needs to tell the reader, with a title it can be recognised by.
    struct AppNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// The doors onto the community list.
    enum CommunitySheet: Identifiable, Equatable {
        /// The list, from the home heading: switch, rename, remove.
        case switcher
        /// Adding a relay this phone can already get into — the same three paths as
        /// onboarding. Enough for an open relay, and not enough for a closed one.
        case add
        /// The pairing scanner on its own, presented rather than pushed.
        ///
        /// The communities list offers this rather than ``add`` because scanning is the one
        /// route that needs nothing typed and nothing asked for, and a reader who came to
        /// the list to bring their desktop identity over was spending a tap reaching it.
        ///
        /// It opened *standing on* the hub at first, so the scanner carried a Back button
        /// to a screen that had never been on the display. The owner reported that, and the
        /// hub is now gone from this route entirely: the scanner is the root of its own
        /// stack and dismisses with a close button. The cost is that Create and Paste are no
        /// longer reachable from the communities list — ``add`` still holds all four, and
        /// nothing presents it today.
        case scan
        /// Redeeming an invitation, which is the only way into a relay that gates on
        /// membership. Carries the invite when one arrived from outside the app.
        case join(InviteLink?)

        /// Identity for `.sheet(item:)`, which re-presents when this changes. An invite
        /// arriving while the join screen is already open is a *different* sheet by this
        /// measure, so the incoming link replaces what is on screen instead of being
        /// swallowed by the presentation already in flight.
        var id: String {
            switch self {
            case .switcher: "switcher"
            case .add: "add"
            case .scan: "scan"
            case let .join(link): "join:\(link?.code ?? "")"
            }
        }
    }

    /// A tap on a reminder's alert. Owned here and not by the sidebar for one reason: its
    /// delegate has to be installed during launch (see ``ReminderAlerts``), and this object
    /// is the only thing built that early. Community-independent, like the object graph
    /// below it is not — the alert names a reminder, and the screen that opens finds it or
    /// does not.
    let reminderAlerts = ReminderAlerts()

    /// The preferences that hold across every community on this phone.
    ///
    /// Owned here rather than by the workspace for the same reason ``reminderAlerts`` is: the
    /// object graph below is rebuilt on every community switch, and a preference that reset
    /// itself when somebody changed community would not be an app-wide preference. See
    /// ``AppSettings``.
    let settings = AppSettings()

    /// A screen Siri, Spotlight or the Shortcuts app has asked for, waiting to be opened.
    ///
    /// Here for the same reason ``reminderAlerts`` is, and one more: an ``AppIntent`` is not
    /// part of the view tree at all, so it needs something it can reach without one. It gets
    /// this object through `@Dependency`, registered once in ``HiveApp/init()``. See
    /// ``AppNavigator`` for why the request is held rather than delivered.
    let navigator = AppNavigator()

    /// The active community's Siri/Spotlight index and the status Settings renders.
    let conversationEntityIndex = ConversationEntityIndex()

    /// The community a pairing session has just committed a key into, held between the
    /// import and ``completePairing()``.
    ///
    /// The two halves of a pairing are separated by the transport: the importer runs inside
    /// the session and can only answer yes or no, and the move to that community can only
    /// happen after the session has acknowledged. Without this the second half would have
    /// to guess — and a pairing started from inside a running community would open the one
    /// already on screen.
    var pairedCommunityID: Community.ID?

    // MARK: - The active community's graph

    /// This community's database, or `nil` before one is open — a fresh install at the
    /// gate, and the moment between two communities.
    ///
    /// One file per community (§ ``Community/storeFilename``). Dropping the reference is
    /// what closes it: GRDB's pool closes when the last handle to it goes, so a switch has
    /// to release the store *and* everything built on it, which is what
    /// ``teardownSession()`` is for.
    private(set) var store: BuzzEventStore?
    /// The signer for the active community's Keychain account.
    private(set) var signer: KeychainSigner?
    /// Every composer's unsent text, for this community. Owned here because a draft
    /// outlives the screen it was typed on, and because the three moments that decide its
    /// fate — leaving the foreground, leaving the community, and signing out — are all
    /// handled here.
    private(set) var drafts: ComposerDrafts?
    /// Built once an identity and relay URL are known; `nil` until then.
    private(set) var engine: SyncEngine?
    /// Puts a composer's pictures on the relay's blob store. Built beside the engine
    /// and dropped with it — see ``makeMediaUploader(websocketURL:)``, which is also
    /// where its separation from the engine is explained.
    private(set) var mediaUploader: (any MediaUploading)?
    /// Signs the reads a gated relay requires before it will serve a blob. Built and
    /// dropped beside the uploader, for the same reason — see
    /// ``installMediaReadAuthorizer(signer:websocketURL:)``.
    ///
    /// Held here as well as installed into the image loaders because the loaders are not
    /// the only thing that fetches a picture: saving and sharing an attachment go out on
    /// their own session (``MessageMediaExport``), from views that reach this through the
    /// environment.
    private(set) var mediaReadAuthorizer: MediaReadAuthorizer?
    /// The authenticated identity's hex pubkey, resolved once the engine starts.
    /// Used to exclude our own typing echo and to key our own presence.
    private(set) var selfPubkeyHex: String?
    /// The community the mounted graph was built for, or `nil` when no session is running.
    /// Set with the graph and cleared with it, so it says *which community is on screen*
    /// rather than which one has been chosen — see ``workspaceMatchesActiveCommunity``.
    private(set) var sessionCommunityID: Community.ID?

    var engineStateTask: Task<Void, Never>?
    var directoryStatusTask: Task<Void, Never>?
    /// The last community transition handed to ``serialisingTransitions(_:)``, which the
    /// next one waits on. `nil` until the first one runs.
    ///
    /// Stored here because an extension cannot hold one, and touched by nothing but that
    /// method — which lives beside the transitions it serialises, in
    /// `AppEnvironment+Communities.swift`.
    var lastTransition: Task<Void, Never>?
    /// A returning user's engine start, which runs *underneath* the mounted workspace
    /// rather than in front of it. Held so sign-out and a switch can wait it out.
    var engineStartTask: Task<Void, Never>?
    /// Whether that start is still in flight. Read by the account sheet, which keeps Sign
    /// Out disabled while it is: signing out mid-start is a teardown racing a setup that
    /// cannot be cancelled (see ``signOut()``), and there is no session to leave yet anyway.
    private(set) var isStartingEngine = false
    /// Publishes our own presence: `"online"` every 60 s while foregrounded, and
    /// `"offline"` on background. Built alongside the engine.
    var heartbeat: PresenceHeartbeat?

    /// Reads the community list, adopting a single-community install as community #1 if
    /// that is what this device is (§ ``CommunityStorage``). No database is opened here:
    /// which one to open is a question about the active community, and a device may have
    /// none yet.
    init(communityStorage: CommunityStorage = CommunityStorage()) {
        self.communityStorage = communityStorage
        let directory = communityStorage.loadAdoptingLegacyInstall(
            hasLegacyIdentity: Self.hasStoredKey(account: Community.legacyKeychainAccount)
        )
        communities = directory
        // Resolved synchronously so a returning user never gets one frame of onboarding
        // while the launch task is being scheduled.
        let hasKey = directory.active.map { Self.hasStoredKey(account: $0.keychainAccount) } ?? false
        phase = hasKey ? .bootstrapping : .needsIdentity
        // The heading draws this before any engine exists, so it is mirrored from the
        // active community rather than left on whatever the last install wrote.
        if let active = directory.active {
            RelayEndpoint.storedURLString = active.relayURLString
        }
        // What a tapped reminder alert *means*. Said here because this is the only object
        // that owns both halves — the notification-centre delegate and the navigator — and
        // because a tap is then indistinguishable from "Open Later in Hive": one queue, one
        // tab selection, one push, and the cold-launch case already solved. See
        // ``ReminderAlerts``.
        //
        // The reminder's id is deliberately dropped. The alert has already said what came
        // due, so the tap is a request for the screen; lighting the row that came due is a
        // separate feature, and `AppDestination` has no room for an argument. The id reaches
        // this closure, which is where that feature would start.
        reminderAlerts.onOpen = { [navigator] _ in
            navigator.request(.destination(.later))
        }
    }

    /// Resolves launch state: if the active community has a key, start its engine;
    /// otherwise rest on the identity gate.
    func bootstrap() async {
        // Queued, not awaited. The delete is a Core Spotlight round trip, and every launch —
        // including a returning user's, which `init` already refuses to spend a frame on — sits
        // behind whatever comes first here. Ordering against the build is the index's own
        // guarantee (``ConversationEntityIndex``), not this call's.
        conversationEntityIndex.reconcileLaunch()
        guard let active = communities.active, Self.hasStoredKey(account: active.keychainAccount) else {
            phase = .needsIdentity
            return
        }
        await startActiveCommunity(mountsBeforeConnect: true)
    }

    // MARK: - Writing the two things a switch changes

    /// Moves the app to another phase.
    ///
    /// Here rather than at each call site because ``phase`` stays `private(set)`: the
    /// community actions live in their own file (`AppEnvironment+Communities.swift`) and
    /// Swift's `private(set)` is file-scoped, so the choice is between opening the setter to
    /// the whole module and giving its two callers a named door. This is the door — nothing
    /// outside this object can still put the app into a phase of its choosing.
    func setPhase(_ next: Phase) {
        phase = next
    }

    /// Changes the community list and writes it down, in that order and always together.
    ///
    /// The pairing is the invariant: a directory mutated but not persisted is a switch that
    /// a relaunch would undo, silently, and only for the reader who quit at the wrong
    /// moment. Nothing outside this object mutates the list, and nothing inside it mutates
    /// the list without saving.
    func updateCommunities(_ body: (inout CommunityDirectory) -> Void) {
        body(&communities)
        communityStorage.save(communities)
    }

    // MARK: - Session lifecycle

    /// Whether a key is stored under `account`. A Keychain that cannot be read at all — CI
    /// has no usable one — answers no, which lands on the gate rather than on a crash.
    static func hasStoredKey(account: String) -> Bool {
        (try? KeychainSigner(account: account).loadPrivateKey()) != nil
    }

    /// Opens the active community: its database, its signer, its engine.
    ///
    /// - Parameter mountsBeforeConnect: whether the workspace may appear before the engine
    ///   has started. True for a launch and for a switch, where a blocking wait on the
    ///   network is the bug; false for the identity gate, where the caller is waiting on a
    ///   verdict about what they just typed.
    func startActiveCommunity(mountsBeforeConnect: Bool) async {
        guard let community = communities.active else {
            phase = .needsIdentity
            return
        }
        do {
            try await startSession(for: community, mountsBeforeConnect: mountsBeforeConnect)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Builds and starts the graph for one community. Throws rather than reporting, so the
    /// identity gate can turn a failure into an answer about the form and a launch can turn
    /// it into ``Phase/failed(_:)``.
    func startSession(for community: Community, mountsBeforeConnect: Bool) async throws {
        guard let websocketURL = RelayEndpoint.websocketURL(from: community.relayURLString),
              let queryURL = RelayEndpoint.queryURL(for: websocketURL)
        else {
            throw CompositionError.invalidRelayURL
        }

        // Before anything else this builds: from here on there is a graph on the way up,
        // and it belongs to exactly one community.
        sessionCommunityID = community.id
        let signer = KeychainSigner(account: community.keychainAccount)
        self.signer = signer
        let store = try Self.makeStore(filename: community.storeFilename)
        self.store = store
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))
        self.drafts = drafts

        // Resolve the identity before the engine writes anything, so a database left by a
        // *different* key (this community re-paired to another identity) is wiped first; a
        // same-key return keeps its history. A community with nothing stored yet has no
        // recorded owner and keeps whatever is there, which is nothing.
        let intendedPubkey = try? await signer.publicKey().hex
        if let intendedPubkey {
            if StoreOwnership.shouldWipe(recordedOwner: community.ownerPubkeyHex, incoming: intendedPubkey) {
                try await store.wipe()
                // Beside the wipe, so "a different key never sees the last one's drafts"
                // holds in memory wherever the handover happens, not only on sign-out.
                drafts.reset()
            }
            recordOwner(intendedPubkey, of: community)
        }

        let engine = makeEngine(store: store, signer: signer, websocketURL: websocketURL, queryURL: queryURL)
        self.engine = engine
        mediaUploader = makeMediaUploader(signer: signer, websocketURL: websocketURL)
        mediaReadAuthorizer = makeMediaReadAuthorizer(signer: signer, websocketURL: websocketURL)
        await installMediaReadAuthorizer(mediaReadAuthorizer)
        heartbeat = PresenceHeartbeat(publisher: engine)

        observeEngineState(of: engine)
        observeDirectoryStatus(of: engine)
        selfPubkeyHex = intendedPubkey
        // Opening the database succeeded above; this final identity-scoped read keeps a
        // later store failure fatal rather than presenting a workspace that cannot answer
        // for itself.
        _ = try store.channelList(selfPubkey: intendedPubkey)

        guard mountsBeforeConnect else {
            // The identity gate. Someone is watching a form they have just filled in, and
            // a relay URL that cannot be reached is their own typing to correct — so here
            // the engine's start *is* awaited, and its failure is the gate's answer.
            try await engine.start()
            // `start()` completes the first directory attempt but does not throw on it:
            // a refusal is a cached fallback, which is right for a workspace already up
            // and wrong here. A closed relay that will not have this key answers every
            // route 403, so letting this through would sign the reader in to a community
            // that can never load — the failure they reported as "it never connects".
            if await engine.directoryRefusedMembership {
                throw CompositionError.relayMembershipRequired
            }
            mountSession(store: store, selfPubkey: intendedPubkey, community: community)
            heartbeat?.startForeground()
            return
        }

        // A launch, or a switch, is not gated on the network. The workspace mounts now —
        // into the sidebar's connecting state, which draws no conversation the relay has not
        // confirmed — and the engine comes up underneath it. There is no longer a window in
        // which a cached list is the best thing on hand, because it is never drawn.
        mountSession(store: store, selfPubkey: intendedPubkey, community: community)
        isStartingEngine = true
        engineStartTask = Task { [weak self] in
            defer { self?.isStartingEngine = false }
            do {
                try await engine.start()
                // Launch is a foreground start, and scene-phase `.onChange` does not fire
                // for the initial value — so the first beat is explicit. After the engine,
                // because presence is published through it.
                self?.heartbeat?.startForeground()
            } catch {
                // All three guards matter: a sign-out or a switch while this was in flight
                // has already dropped this engine, and this throw is likely *because* of it
                // — the key it needed is gone, or the community is. A terminal failure
                // written over the onboarding gate, or over another community's workspace,
                // strands the reader on a screen with nothing on it.
                guard let self, self.engine === engine, self.phase == .running else { return }
                self.phase = .failed(String(describing: error))
            }
        }
    }

    /// Stops and drops the active community's whole graph, leaving the app with no session.
    ///
    /// Shared by sign-out and by a community switch, because they need exactly the same
    /// thing: nothing built on the outgoing identity, relay or database may still be
    /// running when the next one starts. Named in the type comment as the one list a new
    /// piece of community-scoped state has to be added to.
    func teardownSession() async {
        engineStateTask?.cancel()
        engineStateTask = nil
        directoryStatusTask?.cancel()
        directoryStatusTask = nil
        // Let a start in flight finish rather than interleaving with it. `SyncEngine.start`
        // suspends on work that cannot be cancelled, so a `stop()` landing mid-start returns
        // first and then start *resumes*, re-arming the observers, the presence sweep and
        // the socket the stop just closed — an authenticated connection for a key that has
        // been deleted, or for the community the reader has just left. ``isStartingEngine``
        // keeps the affordances off screen while this is pending, so there is normally
        // nothing to wait for; this is the guarantee behind that.
        if let engineStartTask {
            await engineStartTask.value
        }
        engineStartTask = nil
        conversationEntityIndex.teardown()
        // Before the store goes: unsent text is written through as it is typed, but a
        // keystroke landing in the same moment as a switch would otherwise be dropped with
        // the database it was on its way into.
        await drafts?.flush()
        if let engine {
            await engine.stop()
        }
        heartbeat = nil
        engine = nil
        // Beside the engine: it signs with a key this session no longer owns.
        mediaUploader = nil
        mediaReadAuthorizer = nil
        await installMediaReadAuthorizer(nil)
        // Held in memory otherwise — see ``ComposerDrafts/reset()``.
        drafts?.reset()
        drafts = nil
        store = nil
        signer = nil
        selfPubkeyHex = nil
        // With the graph, not with the choice: nothing is mounted, so nothing is anyone's.
        sessionCommunityID = nil
        engineState = .stopped
        hasConnectedBefore = false
        channelDirectoryStatus = .checking
    }

    /// Applies the active community's per-community Siri preference immediately.
    ///
    /// Synchronous end to end, which is what lets the Settings toggle call it directly rather
    /// than spawning a task per tap: the preference write and the index request then happen in
    /// the order the taps were made, rather than in whatever order two unstructured tasks
    /// happened to start.
    func setSiriIndexingEnabled(_ enabled: Bool) {
        guard var community = communities.active else { return }
        community.siriIndexingEnabled = enabled
        updateCommunities { $0.update(community) }

        guard sessionCommunityID == community.id, let store else {
            if !enabled { conversationEntityIndex.teardown(nextState: .off) }
            return
        }
        if enabled {
            conversationEntityIndex.rebuild(store: store, selfPubkey: selfPubkeyHex, community: community)
        } else {
            conversationEntityIndex.teardown(nextState: .off)
        }
    }

    /// Declares the session running and asks for its Siri index.
    ///
    /// The Core Spotlight half is queued rather than awaited, so neither the websocket start
    /// below nor the gate's heartbeat waits on it. What §4 wanted from an `await` here — that a
    /// fast double switch cannot interleave two rebuilds — is provided by the index's own
    /// ordering instead. The half that must not be late is not queued at all: the snapshot an
    /// intent's push reads for a name is written synchronously inside this call, in the same
    /// turn as `phase = .running`.
    private func mountSession(
        store: BuzzEventStore,
        selfPubkey: String?,
        community: Community
    ) {
        phase = .running
        conversationEntityIndex.rebuild(store: store, selfPubkey: selfPubkey, community: community)
    }

    private func observeEngineState(of engine: SyncEngine) {
        engineStateTask?.cancel()
        engineStateTask = Task { [weak self] in
            let states = await engine.states()
            for await state in states {
                self?.engineState = state
                if state == .running { self?.hasConnectedBefore = true }
            }
        }
    }

    private func observeDirectoryStatus(of engine: SyncEngine) {
        directoryStatusTask?.cancel()
        directoryStatusTask = Task { [weak self] in
            let statuses = await engine.channelDirectoryStatuses()
            for await status in statuses {
                self?.channelDirectoryStatus = status
            }
        }
    }

    enum CompositionError: Error {
        case invalidRelayURL
        /// The relay is closed and this key is not a member of it. Only ever thrown on the
        /// gate's path, where the alternative is presenting an empty workspace that will
        /// say "connecting" until the reader gives up.
        case relayMembershipRequired
    }
}
