import BuzzKit
import Foundation
import NostrCore
import OSLog

/// Joining, leaving and moving between communities.
///
/// Every path here ends in the same order, and the order is the point: write the directory
/// down, stop the outgoing graph completely, then build the incoming one. The choice is
/// durable first so a crash mid-switch relaunches into the community the reader chose
/// rather than the one they left; the teardown is complete before the start because two
/// engines authenticating as two identities against two relays under one UI is exactly the
/// state that makes switching look unreliable.
extension AppEnvironment {
    // MARK: - One at a time

    /// Runs a community transition with no other transition in flight.
    ///
    /// Switching, joining and removing all do the same three things — write the choice down,
    /// stop the running graph, build the next one — and not one of them is atomic: each
    /// suspends while an engine stops and another starts. Two of them interleaved is two
    /// engines authenticating as two identities against two relays under one UI, which is
    /// precisely the state this feature exists to avoid. `@MainActor` does not prevent it:
    /// it serialises *steps*, not the stretches between two `await`s.
    ///
    /// It is reachable, not theoretical. A switch to a relay that is slow to stop leaves the
    /// heading tappable, so the reader can open the list again and choose a third community
    /// while the second one is still coming up.
    ///
    /// The second choice is queued rather than dropped: dropping it would mean a tap that
    /// did nothing, with nothing on screen explaining why. Each transition re-reads its own
    /// preconditions when it gets its turn — a switch to what has meanwhile become the
    /// active community is a no-op by its own guard, and one to a community that has
    /// meanwhile been removed cannot find it.
    func serialisingTransitions<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = lastTransition
        let transition = Task { @MainActor in
            await previous?.value
            return await body()
        }
        lastTransition = Task { @MainActor in _ = await transition.value }
        return await transition.value
    }

    // MARK: - The frame that must never be drawn

    /// Whether the graph now mounted belongs to the community the reader has chosen.
    ///
    /// A switch changes two things: which community is chosen, and which graph is running.
    /// It writes the choice down first and replaces the graph afterwards
    /// (§ ``switchCommunity(to:)``), so between those two moments the app knows it is in
    /// community B while still holding community A's store and engine. Drawing then is the
    /// one visible failure this feature can have: **A's conversations under B's name.**
    ///
    /// Today no frame falls in that gap, because the choice and the phase change are two
    /// adjacent statements with no `await` between them. That is an argument about statement
    /// order, and it is not one the next change to this file will be forced to re-make — an
    /// `await` slipped between them brings the frame back with nothing to catch it. So the
    /// frame is refused structurally instead: ``RootView`` draws the workspace only while
    /// this is true, and shows the connecting screen under the *incoming* community's name
    /// while it is not, which is what a switch already looks like.
    var workspaceMatchesActiveCommunity: Bool {
        Self.workspaceMatchesActiveCommunity(
            sessionCommunityID: sessionCommunityID,
            activeCommunityID: communities.activeID,
            hasEngine: engine != nil,
            hasStore: store != nil
        )
    }

    /// ``workspaceMatchesActiveCommunity`` as a decision about four values, so it can be
    /// asserted over states a test cannot otherwise reach: building a real session needs a
    /// key in the Keychain and a relay on the other end, and CI has neither.
    static func workspaceMatchesActiveCommunity(
        sessionCommunityID: Community.ID?,
        activeCommunityID: Community.ID?,
        hasEngine: Bool,
        hasStore: Bool
    ) -> Bool {
        guard hasEngine, hasStore else { return false }
        guard let sessionCommunityID, let activeCommunityID else { return false }
        return sessionCommunityID == activeCommunityID
    }

    // MARK: - The identity gate

    /// Completes the identity gate with a pasted `nsec`: validates the relay, decodes the
    /// key, commits it to the community that relay belongs to, and opens it. The secret
    /// never leaves the Keychain — the decoded key is handed straight to the signer and not
    /// retained here.
    /// The relay is taken in either of the two forms people actually have one written down
    /// in — the socket URL a relay operator quotes (`wss://…`) and the web address the same
    /// relay serves its own pages on (`https://…`) — and reduced to the socket form the
    /// engine connects on. A community is identified by that reduced string
    /// (``Community/relayIdentity(of:)`` accepts only `ws`/`wss`), so normalising here rather
    /// than at the field is what stops the same relay pasted in its two forms from becoming
    /// two communities.
    func submitIdentity(relayURLString: String, nsec: String) async -> IdentityGateError? {
        guard let relay = RelayEndpoint.websocketURLString(fromAnyRelay: relayURLString) else {
            return .invalidRelayURL
        }
        let trimmedSecret = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = try? PrivateKey(nsec: trimmedSecret) else {
            return .invalidSecretKey
        }
        return await joinCommunity(relayURLString: relay, key: key)
    }

    /// Creates a brand-new identity in-app: a fresh secp256k1 key, committed to the
    /// community for the given relay. The generated key is handed straight to the signer
    /// and never retained here — the same custody discipline as the paste path.
    func createIdentity(relayURLString: String) async -> IdentityGateError? {
        guard let relay = RelayEndpoint.websocketURLString(fromAnyRelay: relayURLString) else {
            return .invalidRelayURL
        }
        guard let key = try? PrivateKey() else {
            return .couldNotStoreKey
        }
        return await joinCommunity(relayURLString: relay, key: key)
    }

    /// Publishes the name and picture a reader gave on the way in, once the community they gave
    /// them to is open.
    ///
    /// Deliberately after the arrival and not part of it. It goes through the ordinary outbox,
    /// so it is durable and retried like any other send, and a failure here is **not** surfaced:
    /// the reader is already in, on the screen they asked for, and a red line about a profile
    /// would report the join as having gone wrong. Both values are theirs to correct from the
    /// account screen either way, which is the same editor this writes through.
    ///
    /// Sent when *either* was answered, and each field carries only what was: a reader who picked
    /// a picture and skipped the name gets a kind-0 with a `picture` and no `name`, rather than
    /// nothing at all.
    ///
    /// **Only ever called for a key this app just minted.** A kind-0 is replaceable, and this
    /// writes a fresh one rather than merging into what the relay already holds the way
    /// ``ProfileModel`` does — so publishing it for a key the reader pasted would silently drop
    /// whatever `about`, `nip05` or `lud16` that identity already had. Both walks that call this
    /// ask for a profile only on the new-key route for exactly that reason.
    ///
    /// # Why the picture is finished here rather than on the step that asked for it
    ///
    /// A built avatar arrives as a recipe (§ ``ArrivalPicture``), because the step it was chosen
    /// on has no engine and therefore nowhere to put a picture. This is the first line of code
    /// after a join that has one. So the draw and the decision about what `picture` ends up
    /// holding both happen here, in the same fire-and-forget task the name already rode.
    ///
    /// # Why the engine is taken on the way in and held across that work
    ///
    /// ``engine`` is a property of this object and every community transition replaces it: a
    /// switch, a removal and a sign-out all nil it in ``teardownSession()``. Reading it *after*
    /// the picture is finished put that work between the join and the read. It used to be a draw
    /// **and an HTTP `PUT`**, and that `PUT` is allowed 60 s of silence and 240 s in total
    /// (§ ``makeMediaUploader(signer:websocketURL:)``) — so anything that ended the session
    /// inside that window took the whole announcement with it, **the name as well as the
    /// picture**, and left the reader in their new community as a `?`. That is the shape of the
    /// defect the owner reported; the guard was silent, so it took a relay's database to find.
    ///
    /// The picture no longer uploads (§ ``publishableValue(for:)``), which leaves a draw and a
    /// window measured in milliseconds. The capture stays anyway, because closing that race was
    /// only one of the things it was doing.
    ///
    /// Captured, the send goes to the engine for the community these two answers were actually
    /// given to — the only community they mean anything on. Sending them through whatever engine
    /// exists a minute later would write a fresh kind-0 for whichever identity the reader has
    /// meanwhile switched to, replacing that profile: the same overwrite the new-key rule above
    /// exists to prevent, reached from the other side.
    ///
    /// Holding it also makes the send *durable* rather than merely correct. `enqueue` writes a
    /// row into the joined community's own database before it tries the relay, so a community
    /// left before the relay answered still keeps its announcement and drains it the next time
    /// it is opened.
    func announceArrivalProfile(displayName: String, picture: ArrivalPicture?) async {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || picture != nil else { return }

        guard let sender = engine else {
            // Not reachable from either walk as they stand — both await a join that returns
            // successfully only once the engine exists — so this is the honest report of a
            // caller that has not, rather than a state to recover from.
            Self.arrivalLog.error("Arrival profile dropped: the joined community has no engine.")
            return
        }

        var value: String?
        if let picture { value = Self.publishableValue(for: picture) }
        if picture != nil, value == nil {
            Self.arrivalLog.notice("Arrival picture could not be drawn; sending the name alone.")
        }

        var content = Self.arrivalMetadata(name: name, picture: value)
        // A backstop rather than a live branch. The inline avatar is exported at a size chosen
        // so this cannot fire (§ ``AvatarKitExport/inlineSide``): the worst of 320 measured
        // bodies came in at two thirds of the ceiling. The only input left that could reach it
        // is a name long enough to matter, and one lands in the body twice — so if it ever
        // does, a name arriving without its picture is the better half of the answer; a refused
        // send is neither half.
        if content.utf8.count > OutboxPolicy.maxContentBytes {
            Self.arrivalLog.notice(
                "Arrival picture dropped: \(content.utf8.count, privacy: .public) bytes over the send ceiling."
            )
            value = nil
            content = Self.arrivalMetadata(name: name, picture: nil)
        }
        // Remembered whatever became of the publish, so the account screen's editor opens on the
        // face the walk produced rather than on a stranger. `publishedURL` is only set to what
        // actually went out, because that is what the editor matches against to recognise its
        // own work (§ ``AvatarKitRecipeStore/Recipe``).
        if case let .built(avatar) = picture {
            AvatarKitPublishedAvatar.record(avatar, publishedAs: value)
        }
        guard !name.isEmpty || value != nil else {
            Self.arrivalLog.notice("Nothing left to announce: no name was given and the picture did not survive.")
            return
        }

        do {
            _ = try await sender.enqueue(
                kind: .metadata,
                content: content,
                in: "",
                tags: [],
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
        } catch {
            // The one failure here that is not recoverable by the outbox: nothing was queued,
            // so nothing will be retried, and the reader has no way to know. Said out loud
            // because the alternative is what this whole method just cost to diagnose.
            Self.arrivalLog.error(
                "Arrival profile could not be queued: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Logger for the arrival announcement, in the same shape and for the same reason as
    /// ``BuzzKit/SyncEngine/channelCreationLog``: this is a verdict nothing else records.
    ///
    /// The send is fire-and-forget by design — a red line about a profile would report a join
    /// that worked as having gone wrong (§ ``announceArrivalProfile(displayName:picture:)``) —
    /// which means every way it can fail is invisible from the outside, and a reader who lands
    /// with no name looks exactly like a reader who chose not to give one. Not `#if DEBUG`: the
    /// point is a phone in somebody else's hand, and the one thing that would have shortened
    /// this diagnosis is a line retrievable from a device that is not attached to a debugger.
    /// Nothing the reader typed is logged, only which branch was taken.
    static let arrivalLog = Logger(subsystem: "Hive", category: "AppEnvironment.arrivalProfile")

    /// The kind-0 body for an arrival, as JSON. Each field carries only what was answered.
    private static func arrivalMetadata(name: String, picture: String?) -> String {
        ProfileMetadataContent(
            name: name.isEmpty ? nil : name,
            displayName: name.isEmpty ? nil : name,
            about: nil,
            picture: picture,
            nip05: nil,
            lud16: nil
        )
        .jsonString()
    }

    /// What a step's answer becomes in the `picture` field, or `nil` if it could not become
    /// anything.
    ///
    /// Both answers become a `data:` URI, and neither touches the network. An emoji is its own
    /// document and has never needed a relay; a built avatar is drawn at
    /// ``AvatarKitExport/inlineSide`` and its bytes are the document.
    ///
    /// # Why an arrival avatar is embedded where the account editor uploads
    ///
    /// The editor uploads, and is right to. It runs in a community the reader has been living
    /// in, against a media host this app has already fetched from, with a Done button to report
    /// a failure to. This runs seconds after a join, for an identity minutes old, on a relay the
    /// app has just met — and a published URL is only worth having if it can be *read back*.
    ///
    /// On a hosted relay it cannot. `GET /media/<sha>` there answers **401 even for a blob that
    /// does not exist**, so a read is authenticated before it is resolved, and nothing in this
    /// app sends an `Authorization` header when it fetches an image. The upload succeeds, the
    /// URL is published, and the picture is undrawable — by the reader who chose it and by
    /// everyone who meets them. Nothing fails loudly enough to notice: this function is called
    /// exactly once, its failures are deliberately silent, and what the reader sees is the `?`
    /// they were promised a face instead of.
    ///
    /// An inline picture has none of that surface. It needs no host, no auth and no network at
    /// the moment it is drawn — the same property that has always made the emoji avatar work
    /// everywhere, and the only one of the two a brand-new identity can rely on. It costs bytes
    /// instead of trust, and ``AvatarKitExport/inlineSide`` is where those bytes were measured
    /// to fit with room to spare.
    ///
    /// The gate itself is the larger defect and not this function's to fix: on such a relay
    /// every photo and every attachment is unreadable for exactly the same reason.
    private static func publishableValue(for picture: ArrivalPicture) -> String? {
        switch picture {
        case let .emoji(glyph, color):
            return EmojiAvatar(emoji: glyph, color: color).dataURL()
        case let .built(avatar):
            guard let png = try? AvatarKitExport.pngData(
                for: avatar,
                side: AvatarKitExport.inlineSide
            ) else { return nil }
            return "data:\(AvatarKitExport.mimeType);base64,\(png.base64EncodedString())"
        }
    }

    /// The application-specific sink a ``TargetPairingSession`` hands its decrypted
    /// credential to. It commits the imported key to the community the credential's relay
    /// belongs to — creating that community if this device does not have it yet — and the
    /// session sends `complete(true)` only if that succeeds.
    ///
    /// Storing the key is all it does. Which community is *open* is not decided here,
    /// because the pairing session is still running at this point and the community it
    /// named is not necessarily the one on screen; ``completePairing()`` makes that move
    /// once the transfer is acknowledged.
    func pairingImporter() -> PairingCredentialImporter {
        PairingCredentialImporter(keyStore: PairedCommunityKeyStore { [weak self] key, relayURLString in
            guard let self else { return false }
            return await self.adoptKey(key, forRelay: relayURLString) != nil
        })
    }

    /// Finishes a completed pairing by opening the community the importer adopted the key
    /// into. The key is already durably stored — that is what let the session acknowledge —
    /// so this only makes the move and brings the connection up.
    func completePairing() async -> IdentityGateError? {
        await serialisingTransitions { [self] in
            let target = pairedCommunityID.flatMap { id in
                communities.communities.first { $0.id == id }
            } ?? communities.active
            guard let target else {
                return .couldNotStart("The pairing did not name a community to open.")
            }
            pairedCommunityID = nil
            return await openFromGate(target, returningTo: communities.activeID)
        }
    }

    // MARK: - Arriving from outside the app

    /// Handles a URL the system handed this app, returning whether it was one Hive knows.
    ///
    /// The only one today is an invitation. It is opened rather than acted on: a link that
    /// silently joined a community on being tapped would make a shared URL into a
    /// membership, and the host it names is exactly the thing the reader has to see before
    /// agreeing to anything.
    ///
    /// The sheet is raised from here — above the workspace's remount boundary — rather than
    /// from whatever screen happens to be up, so an invite tapped while a conversation is
    /// open lands the same way as one tapped on the sidebar.
    @discardableResult
    func handle(incomingURL url: URL) -> Bool {
        guard let link = InviteLink.parse(url.absoluteString) else { return false }
        communitySheet = .join(link)
        return true
    }

    // MARK: - Moving between communities

    /// Opens another community: stops the current one, then brings up its relay, its
    /// identity and its database.
    ///
    /// Between the two, ``Phase/bootstrapping`` draws the incoming community's name over an
    /// empty sidebar rather than the outgoing community's rows — the frame that would
    /// otherwise show one community's conversations under another's name.
    ///
    /// A community whose key has been signed out of lands on the identity gate instead,
    /// with its relay prefilled. That is how you sign back into one: the gate re-adopts the
    /// record already on the device, so the history it kept is still its own.
    func switchCommunity(to id: Community.ID) async {
        await serialisingTransitions { [self] in
            guard id != communities.activeID else { return }
            updateCommunities { $0.setActive(id) }
            guard let community = communities.active, community.id == id else { return }
            RelayEndpoint.storedURLString = community.relayURLString
            setPhase(.bootstrapping)
            await teardownSession()
            guard Self.hasStoredKey(account: community.keychainAccount) else {
                setPhase(.needsIdentity)
                return
            }
            await startActiveCommunity(mountsBeforeConnect: true)
            refreshCommunityIcon(for: community)
        }
    }

    /// Renames a community. A label on this device only: no relay has a name to disagree
    /// with (§ ``CommunityIdentity``).
    func renameCommunity(_ id: Community.ID, to name: String) {
        updateCommunities { $0.rename(id, to: name) }
    }

    /// Leaves a community for good on this device: its key is deleted, its record is
    /// dropped, and the database holding its history goes with it.
    ///
    /// Unlike ``signOut()``, this one *is* destructive, and deliberately: the record is what
    /// names the database file (§ ``Community/storeFilename``), so keeping the file after
    /// dropping the record would leave that community's messages on the device with nothing
    /// able to open it, list it, or ever delete it.
    ///
    /// Removing the community being read hands over to the next one in the list, or to
    /// onboarding when it was the last.
    func removeCommunity(_ id: Community.ID) async {
        await serialisingTransitions { [self] in await performRemoval(of: id) }
    }

    private func performRemoval(of id: Community.ID) async {
        let wasActive = id == communities.activeID
        var removedCommunity: Community?
        updateCommunities { removedCommunity = $0.remove(id) }
        guard let removed = removedCommunity else { return }
        if wasActive {
            setPhase(.bootstrapping)
            await teardownSession()
        }
        try? KeychainSigner(account: removed.keychainAccount).delete()
        // After the teardown, so the file is not deleted underneath an open connection:
        // dropping the store is what closes it.
        Self.deleteStore(filename: removed.storeFilename)
        communityStorage.removeIcon(for: removed)
        guard wasActive else { return }
        guard let next = communities.active, Self.hasStoredKey(account: next.keychainAccount) else {
            setPhase(.needsIdentity)
            if let next = communities.active {
                RelayEndpoint.storedURLString = next.relayURLString
            }
            return
        }
        RelayEndpoint.storedURLString = next.relayURLString
        await startActiveCommunity(mountsBeforeConnect: true)
    }

    /// Records the identity a community's database now belongs to, so the next sign-in to
    /// it can tell a returning key from a new one (§ ``StoreOwnership``).
    func recordOwner(_ pubkeyHex: String, of community: Community) {
        guard community.ownerPubkeyHex != pubkeyHex else { return }
        var updated = community
        updated.ownerPubkeyHex = pubkeyHex
        updateCommunities { $0.update(updated) }
    }

    // MARK: - Joining

    /// Commits `key` as the identity for `relayURLString`'s community, creating the
    /// community if this device does not have it yet. Returns the community it landed in,
    /// or `nil` if the key could not be stored.
    ///
    /// Find-or-create, rather than always-create, is what both other clients do
    /// (`community_provider.dart:24-42`; Desktop's `addCommunity`), and here it is also what
    /// makes signing back in after a sign-out keep a community's history: the record is
    /// matched on the relay, so the same database file is reopened and the recorded owner
    /// decides whether its contents survive.
    ///
    /// It does not change which community is open. ``openFromGate(_:returningTo:)`` does
    /// that, once the caller knows a switch is safe to make.
    @discardableResult
    func adoptKey(_ key: PrivateKey, forRelay relayURLString: String) async -> Community? {
        let existing = communities.community(forRelay: relayURLString)
        let community = existing ?? .new(relayURLString: relayURLString)
        do {
            try KeychainSigner(account: community.keychainAccount).store(key)
        } catch {
            return nil
        }
        if existing == nil {
            updateCommunities { $0.add(community) }
        }
        pairedCommunityID = community.id
        return community
    }

    /// Adopts a key for a relay and opens it, reporting the gate's answer. Shared by the
    /// paste and create paths, and by adding a community from inside the app.
    func joinCommunity(relayURLString: String, key: PrivateKey) async -> IdentityGateError? {
        await serialisingTransitions { [self] in
            let previousID = communities.activeID
            guard let joined = await adoptKey(key, forRelay: relayURLString) else {
                return .couldNotStoreKey
            }
            pairedCommunityID = nil
            return await openFromGate(joined, returningTo: previousID)
        }
    }

    /// Opens `community` with someone watching a form they have just filled in: the engine
    /// start is *awaited*, and its failure is the answer they get.
    ///
    /// A community that cannot be started is still left in the list, with its key. Undoing
    /// the join on a failed connection would throw away credentials the reader has just
    /// entered because a relay happened to be unreachable — the commonest reason for this
    /// to fail, and the one that fixes itself. What is undone is the *move*: they are put
    /// back in the community they were reading rather than dropped onto onboarding with a
    /// working community still on the device.
    private func openFromGate(_ community: Community, returningTo previousID: Community.ID?) async
        -> IdentityGateError? {
        updateCommunities { $0.setActive(community.id) }
        RelayEndpoint.storedURLString = community.relayURLString
        if engine != nil {
            setPhase(.bootstrapping)
            await teardownSession()
        }
        do {
            setPhase(.bootstrapping)
            try await startSession(for: community, mountsBeforeConnect: false)
            refreshCommunityIcon(for: community)
            // The sheet the reader joined from went with the workspace it was attached to;
            // closing it here is what makes a successful join end on the new community
            // rather than on a form that has nothing left to do.
            communitySheet = nil
            notice = nil
            return nil
        } catch {
            let failure = Self.gateAnswer(for: error)
            await teardownSession()
            await returnToCommunity(previousID, after: community.id)
            // Only worth saying out here if the reader was put back somewhere: the gate
            // shows this error itself, and saying it twice is how one failure reads as two.
            if phase != .needsIdentity {
                notice = AppNotice(title: "Couldn't open that community", message: failure.message)
            }
            return failure
        }
    }

    /// The sentence a failed start is worth to the person who caused it.
    ///
    /// Only the failures a reader can act on differently are named; everything else keeps
    /// its `String(describing:)`, which is deliberately a developer's description because
    /// the alternative is inventing advice for a failure nobody has diagnosed yet.
    private static func gateAnswer(for error: any Error) -> IdentityGateError {
        switch error {
        case CompositionError.relayMembershipRequired: .needsInvitation
        default: .couldNotStart(String(describing: error))
        }
    }

    /// Puts the reader back where they were after a join that could not be started.
    private func returnToCommunity(_ id: Community.ID?, after joinedID: Community.ID) async {
        guard let id, id != joinedID, communities.communities.contains(where: { $0.id == id }) else {
            setPhase(.needsIdentity)
            return
        }
        updateCommunities { $0.setActive(id) }
        guard let previous = communities.active,
              Self.hasStoredKey(account: previous.keychainAccount)
        else {
            setPhase(.needsIdentity)
            return
        }
        RelayEndpoint.storedURLString = previous.relayURLString
        await startActiveCommunity(mountsBeforeConnect: true)
    }

    // MARK: - Community mark

    /// Refreshes the relay-owned community icon after opening a community.
    ///
    /// The information document is unauthenticated, so this does not delay engine startup or
    /// make the icon a condition of joining. It is a best-effort cache refresh: a failed
    /// lookup keeps the last good picture, while a successful document with no icon removes
    /// the old one and returns the switcher to initials. This is also the join capture path —
    /// the new record is opened immediately after the relay accepts its key.
    func refreshCommunityIcon(for community: Community) {
        Task { [weak self] in
            guard let self,
                  let client = RelayInfoClient(
                      relayURLString: community.relayURLString,
                      transport: URLSessionHTTPTransport()
                  ),
                  let info = try? await client.fetch(),
                  info.isBuzzRelay
            else { return }

            let data: Data?
            switch info.communityIcon {
            case nil:
                data = nil
            case let .some(icon):
                // A failed remote fetch is not the same thing as a relay that removed its
                // icon. Keep the last good cache in that case.
                guard let fetched = await Self.iconData(from: icon) else { return }
                data = fetched
            }

            guard let current = self.communities.communities.first(where: { $0.id == community.id })
            else { return }
            guard let updated = try? self.communityStorage.replacingIcon(data, for: current) else {
                return
            }
            self.updateCommunities { $0.update(updated) }
        }
    }

    /// Reads a remote icon through the same HTTP transport boundary as relay metadata and
    /// refuses a response larger than the inline icon limit before it reaches disk. Hosted
    /// Buzz icons are inline; this branch keeps custom relays' HTTPS icons equally durable.
    private static func iconData(from icon: RelayIcon) async -> Data? {
        switch icon {
        case let .inline(data):
            return data
        case let .remote(url):
            guard let (data, status) = try? await URLSessionHTTPTransport().get(
                from: url,
                headers: [:]
            ), (200 ... 299).contains(status), !data.isEmpty,
                data.count <= RelayIcon.maximumInlineBytes
            else { return nil }
            return data
        }
    }
}

/// The importer's route into the community list: it holds a credential's key and the relay
/// it came from, and the app decides which community that is.
///
/// A closure behind the protocol rather than the signer itself, because the destination is
/// no longer known before the payload is parsed — a paired credential names its own relay,
/// and that relay may be a community this device does not have yet.
struct PairedCommunityKeyStore: PairedKeyStoring {
    let adopt: @Sendable (PrivateKey, String) async -> Bool

    func storePairedKey(_ key: PrivateKey, forRelay relayURLString: String) async -> Bool {
        await adopt(key, relayURLString)
    }
}
