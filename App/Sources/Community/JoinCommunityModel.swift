import BuzzKit
import Foundation
import NostrCore

/// Joining a community this phone is not in yet.
///
/// # Why this is a separate thing from adding one
///
/// ``OnboardingView`` in its `isAddingCommunity` mode already adds a community: you type a
/// relay, you supply an identity, and the engine connects. That works on an **open** relay —
/// one whose operator has left `require_relay_membership` off, which is what a self-hosted
/// relay usually is.
///
/// It cannot work on a **closed** one. A closed relay answers 403 to every HTTP call from a
/// key it does not know, so the socket connects, the engine starts, and the sidebar sits on
/// `Can't reach the relay` for ever. The only way into that relay's member list from a
/// client is to redeem an invite (`buzz/crates/buzz-relay/src/api/invites.rs:5-10`), and
/// that is what this does. Every community published on a directory like `buzzdir.xyz` is
/// closed, so without this the answer to "can Hive join a public community" is no.
///
/// # The order, and why the claim comes first
///
/// 1. Read the link (§ ``BuzzKit/InviteLink``).
/// 2. Ask the relay what it requires of a joiner, and — when it requires something — get the
///    reader's actual acceptance and exchange it for a receipt.
/// 3. Claim the code, signed by the key that will own this community.
/// 4. Only then commit that key to the Keychain and open the community, through the
///    ordinary ``AppEnvironment/joinCommunity(relayURLString:key:)`` path.
///
/// Claiming before committing is deliberate. A refused invite must leave nothing behind: no
/// key in the Keychain, no row in the community list, no database file — because the
/// commonest refusal is `invite_exhausted`, and a phone that collected a dead community
/// every time somebody shared a used link would fill its switcher with entries that can
/// never connect.
@MainActor
@Observable
final class JoinCommunityModel {
    /// How far along the reader is.
    ///
    /// # Why this is two screens now and was one before
    ///
    /// It was one deliberately: a reader is making one decision — *do I want to be in this* —
    /// and everything for it belonged in front of them at once. What broke that is that the
    /// screen grew a third thing. It now carries the community and its terms, **and** a name,
    /// **and** a choice of identity, and only the first of those is the decision. The other
    /// two are consequences of having already made it, and asking somebody to pick which key
    /// they will be before they have decided they want in is asking them to furnish a room
    /// they have not agreed to rent.
    ///
    /// So the split is along the decision, not down the middle of the form: ``community`` is
    /// *which community, and on what terms*, ``profile`` is *who you will be there*, and
    /// ``identity`` is *which key signs for you*. Desktop draws the same three — its spotlight
    /// step redeems the invite and says `Next` (`InviteRedeemForm.tsx:317`), and the profile
    /// and key steps follow it separately (`CommunityOnboardingFlow.tsx`).
    ///
    /// # Why the profile is its own step and not a section
    ///
    /// It was a name field at the top of the key step. That put the two least similar questions
    /// on the screen in one place: *what should this community call you* is a warm question
    /// anybody can answer in four seconds, and *which cryptographic key owns this community* is
    /// a question with a paste field and a warning under it. Stacked together the second sets
    /// the tone for both, and the name — the field that decides whether everyone here sees a
    /// person or a 63-character `npub` — gets skipped as part of the paperwork. Given a screen
    /// of its own, with a face on it, it gets answered.
    enum Step: Equatable {
        /// No usable link yet.
        case needsLink
        /// A link, and whatever the relay says it wants of a joiner. The decision point.
        case community
        /// How this community will see the reader: their name here, and their picture.
        case profile
        /// The key that owns this community.
        case identity
        /// Talking to the relay.
        case joining
    }

    /// Which identity will own this community.
    ///
    /// The Flutter client always generates a fresh key for an invite
    /// (`invite_join_provider.dart:120`), and that is the right default: a community you
    /// were invited to by a stranger has no claim on the identity you use elsewhere.
    /// Pasting an existing key is offered because a reader moving between their own devices
    /// wants the opposite, and it is the same key custody the identity gate already has.
    enum Identity: String, CaseIterable, Identifiable {
        case new
        case existing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .new: "New identity"
            case .existing: "Existing key"
            }
        }
    }

    // MARK: - What the reader typed

    /// The link, as pasted. Re-read on every change, so a half-typed link simply has not
    /// resolved yet rather than being an error.
    var linkText = "" {
        didSet { linkTextChanged() }
    }

    var identity: Identity = .new
    /// The `nsec` for ``Identity/existing``. Held only until it is handed to the signer.
    var nsec = ""
    /// What this community should call the reader.
    ///
    /// Optional, and never blocks the join: a relay admits a key, not a name. But a fresh
    /// identity has no profile at all, so without this the first thing everyone in the
    /// community sees of a new member is a 63-character `npub` — and the moment to fix that
    /// is the one moment the reader is already filling a form in. Published as an ordinary
    /// kind-0 after the community is open (§ ``announceDisplayName()``).
    var displayName = ""
    /// The glyph on the reader's picture, or `nil` while they have not picked one.
    ///
    /// `nil` rather than a default emoji, on purpose. A default gives every member of a
    /// community the same face on the day they joined, which is worse than no face at all: the
    /// app already draws a stable per-key monogram where there is no picture, and that at least
    /// differs between people. So a picture is published only if one was actually chosen.
    ///
    /// Emoji only, where the account screen's editor also takes a photo — because a photo has
    /// to be uploaded to the community's media server, and at this point in the flow there is
    /// no community, no key committed, and no engine to upload through. An emoji avatar is a
    /// `data:` URI (§ ``EmojiAvatar``) needing nothing but the two values beside it, which is
    /// why Buzz's own clients store the workspace owner's avatar as one.
    var avatarEmoji: String?
    /// The background behind ``avatarEmoji``, as an uppercase `#RRGGBB` string.
    var avatarColor = EmojiAvatar.defaultColor
    /// The reader's own answer to a relay that requires an age attestation. Never set by
    /// this app on their behalf — the relay refuses a receipt without it, and that refusal
    /// is the correct outcome of not ticking the box.
    var ageConfirmed = false
    /// That the reader agrees to the documents this community publishes.
    ///
    /// Hive had no such switch: it listed the Terms and the Privacy Policy as two buttons and
    /// then took *pressing Join* as agreement to both. Desktop does not — it holds its own
    /// button until an `I agree to the Buzz Terms of Service and Privacy Policy` box is ticked
    /// (`desktop/src/features/onboarding/ui/JoinPolicyNotice.tsx:60-105`, gated at
    /// `InviteRedeemForm.tsx:303-307`) — and a relay that took the trouble to publish terms is
    /// owed the same acceptance from both clients.
    ///
    /// It is not part of the receipt: `POST /api/join-policy/accept` carries the version and
    /// the age answer and nothing else (§ ``BuzzKit/InviteClient/acceptPolicy(code:policyVersion:ageConfirmed:)``).
    /// Presenting a receipt for a version *is* the acceptance as far as the relay is
    /// concerned; this switch is what makes the reader's half of it deliberate rather than
    /// inferred from a tap on a button labelled something else.
    var termsAccepted = false

    // MARK: - What the app knows

    private(set) var step: Step = .needsLink
    private(set) var link: InviteLink?
    /// What this relay asks of a joiner, or `nil` if it asks nothing — which is most relays,
    /// and is also the state before the question has been asked.
    private(set) var policy: JoinPolicy?
    private(set) var isReadingPolicy = false
    /// The community on this phone that is already this relay, if there is one. Joining is
    /// then not the operation — opening is.
    private(set) var alreadyJoined: Community?
    private(set) var error: String?
    /// The community behind this link, as far as its own relay will say — the card at the top
    /// of the screen. Driven from the link, so it fills in the moment one parses and before
    /// any identity exists.
    let lookup: CommunityLookup

    private let environment: AppEnvironment
    private let makeClient: @Sendable (String) -> InviteClient?
    /// Guards against a policy fetch for a link the reader has since replaced.
    private var policyTask: Task<Void, Never>?

    /// - Parameters:
    ///   - initialLink: an invite that arrived from outside the app — a `buzz://join`
    ///     handoff from the relay's own web page. Its receipt, when it has one, is what lets
    ///     the join skip the terms step: it was already taken, in a browser.
    ///   - makeClient: the invite client for a relay URL; injectable so the flow can be
    ///     driven in a test without a relay.
    init(
        environment: AppEnvironment,
        initialLink: InviteLink? = nil,
        lookup: CommunityLookup = CommunityLookup(),
        makeClient: @escaping @Sendable (String) -> InviteClient? = { relay in
            InviteClient(relayURLString: relay, transport: URLSessionHTTPTransport())
        }
    ) {
        self.environment = environment
        self.lookup = lookup
        self.makeClient = makeClient
        if let initialLink {
            linkText = initialLink.absoluteText
            adopt(initialLink)
        }
    }

    // MARK: - Reading the link

    private func linkTextChanged() {
        let parsed = InviteLink.parse(linkText)
        // The same invitation re-parsed is not a change. `didSet` fires on every assignment,
        // including a same-value write-back, and re-adopting would cancel a policy fetch
        // already in flight and start it again while the reader watches a spinner.
        //
        // Compared on the *invitation* — the relay and the code — rather than on the whole
        // value, because this field shows an invite in its `https` form and that form
        // carries no receipt (§ ``BuzzKit/InviteLink/absoluteText``). Comparing everything
        // would throw a handoff's acceptance away on the first write-back of text the reader
        // never touched, and silently turn a one-tap join into the terms screen again.
        guard parsed?.relayURLString != link?.relayURLString || parsed?.code != link?.code else {
            return
        }
        adopt(parsed)
    }

    private func adopt(_ parsed: InviteLink?) {
        policyTask?.cancel()
        link = parsed
        policy = nil
        error = nil
        ageConfirmed = false
        termsAccepted = false
        alreadyJoined = nil
        // Cleared here rather than in each branch below: two of the three ways out of this
        // method ask the relay nothing, and a reader who replaces an invite to a stranger's
        // relay with one to a community they are already in would otherwise be left looking
        // at terms loading for a question nobody is going to answer.
        isReadingPolicy = false
        lookup.look(at: parsed?.relayURLString)
        guard let parsed else {
            step = .needsLink
            return
        }
        // Back to the first step, even if the reader had already reached the second: they
        // have replaced the community, and the terms they agreed to were the old one's.
        step = .community
        alreadyJoined = environment.communities.communities.first { $0.isSameRelay(as: parsed.relayURLString) }
        // A community already on this phone needs no invite: the reader is a member, and
        // the operation in front of them is opening it. Asking its relay for a join policy
        // would be a question about a decision that is not being made.
        guard alreadyJoined == nil else { return }
        readPolicy(for: parsed)
    }

    /// Asks the relay what it requires, ahead of the reader deciding.
    ///
    /// A failure here is deliberately **not** shown. This runs before anything has been
    /// asked of the reader, and the endpoint is the one part of the flow a relay may simply
    /// not implement — an older relay 404s it. Reporting "couldn't reach the relay" at that
    /// moment would condemn a join that is about to work. The join itself is where an
    /// unreachable relay is reported, because there the reader has asked for something.
    private func readPolicy(for link: InviteLink) {
        guard let client = makeClient(link.relayURLString) else { return }
        isReadingPolicy = true
        policyTask = Task { [weak self] in
            let fetched = try? await client.joinPolicy()
            guard let self, !Task.isCancelled else { return }
            // The link may have been replaced while this was in flight.
            guard self.link == link else { return }
            self.policy = fetched
            self.isReadingPolicy = false
        }
    }

    // MARK: - Moving between the steps
    //
    // What each step is *waiting for*, and what its button says, is § ``JoinCommunityFlow`` —
    // all derived, all read-only. What moves the reader between them stays here, beside the
    // `private(set)` state it sets.

    /// What the button on this step does: go on to the next one, open a community already
    /// here, or join.
    ///
    /// One entry point rather than the view switching on ``step`` itself, so the button's
    /// meaning and the button's label (§ ``actionTitle``) cannot come apart.
    func primaryAction() async {
        guard canContinue else { return }
        switch step {
        case .needsLink, .joining:
            return
        case .community:
            // A community already on this phone has no further steps: there is no identity to
            // choose, because the one it is already signed in with is the answer — and no name
            // or picture to ask for either, since the profile it has is already published.
            if alreadyJoined != nil {
                await submit()
            } else {
                step = .profile
            }
        case .profile:
            step = .identity
        case .identity:
            await submit()
        }
    }

    /// One step back. Keeps everything the reader has typed: this is a step back to re-read or
    /// re-answer something, not a cancellation.
    func goBack() {
        switch step {
        case .identity: step = .profile
        case .profile: step = .community
        case .needsLink, .community, .joining: return
        }
    }

    // MARK: - Doing it

    /// Runs the join, reporting into ``error`` and leaving the screen up if it fails.
    func submit() async {
        guard canContinue, let link else { return }
        error = nil

        // Already a member on this device. Redeeming the code again would succeed —
        // claiming is idempotent — but it would spend a use of an invite that may be
        // bounded, to learn something this phone already knows.
        if let alreadyJoined {
            // Closed before the switch, for the reason ``CommunitySwitcherView`` gives: the
            // switch remounts the workspace underneath this sheet, and a sheet still up when
            // its presenter is replaced vanishes without reading as an answer to the tap.
            environment.communitySheet = nil
            await environment.switchCommunity(to: alreadyJoined.id)
            return
        }

        guard let client = makeClient(link.relayURLString) else {
            error = Self.message(for: .invalidRelayURL)
            return
        }
        guard let key = resolveKey() else {
            error = "That key isn't a valid nsec."
            return
        }

        let returnTo = step
        step = .joining
        // Back to the step the reader pressed from, so a refused join leaves them looking at
        // the controls their next attempt will use rather than at the first screen again with
        // their key thrown away.
        defer { if step == .joining { step = returnTo } }

        do {
            let receipt = try await policyReceipt(link: link, client: client)
            _ = try await client.claim(
                code: link.code,
                policyReceipt: receipt,
                signer: InMemorySigner(key)
            )
        } catch is CancellationError {
            return
        } catch let inviteError as InviteError {
            error = Self.message(for: inviteError)
            return
        } catch {
            self.error = "Could not join this community: \(error)"
            return
        }

        // The relay has admitted this key. From here the ordinary join path takes over —
        // Keychain, community record, database, engine — and its failures are the same ones
        // the identity gate reports.
        if let failure = await environment.joinCommunity(relayURLString: link.relayURLString, key: key) {
            error = failure.message
            return
        }
        await announceProfile()
    }

    /// Publishes the name and picture the reader gave, once the community they gave them to is
    /// open. The writing itself is
    /// ``AppEnvironment/announceArrivalProfile(displayName:emoji:color:)``, shared with the
    /// onboarding walks.
    ///
    /// **Only on the new-key route.** The profile step comes before the key step, so a reader
    /// answers it without having said yet which key will sign — and that helper writes a *fresh*
    /// kind-0 rather than merging into what the relay already holds. On a pasted key that would
    /// replace an existing profile, dropping its `about`, `nip05` and `lud16` and whichever of
    /// name and picture was left blank here. A key this app just minted has nothing to lose,
    /// which is the only case where writing a whole profile from two answers is safe.
    /// ``JoinCommunityGuidance/existingIdentityBlurb`` says so on the step where it matters.
    private func announceProfile() async {
        guard identity == .new else { return }
        await environment.announceArrivalProfile(
            displayName: displayName,
            emoji: avatarEmoji,
            color: avatarColor
        )
    }

    /// The acceptance to present with the claim: the one the link already carries, or one
    /// obtained now from what the reader agreed to on screen.
    ///
    /// A relay with no policy gets `nil`, which is what it expects.
    private func policyReceipt(link: InviteLink, client: InviteClient) async throws -> String? {
        if let carried = link.policyReceipt { return carried }
        guard let policy else { return nil }
        return try await client.acceptPolicy(
            code: link.code,
            policyVersion: policy.version,
            ageConfirmed: ageConfirmed
        )
    }

    /// The key that will own this community: a fresh one, or the pasted one.
    private func resolveKey() -> PrivateKey? {
        switch identity {
        case .new:
            return try? PrivateKey()
        case .existing:
            return try? PrivateKey(nsec: nsec.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension InviteLink {
    /// The link as text a field can show and re-parse — the `https` form, which is the one
    /// people share. A `buzz://join` handoff is reduced to it, minus the receipt, which is
    /// held on the parsed value rather than shown.
    var absoluteText: String {
        let scheme = relayURLString.hasPrefix("wss://") ? "https" : "http"
        return "\(scheme)://\(host)/invite/\(code)"
    }
}
