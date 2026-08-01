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
    /// How far along the reader is. Not a wizard — the whole thing is one screen — but the
    /// screen shows different things at each of these, and the join button means different
    /// things too.
    enum Step: Equatable {
        /// No usable link yet.
        case needsLink
        /// A link, and whatever the relay says it wants. The decision point.
        case reviewing
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
    /// The reader's own answer to a relay that requires an age attestation. Never set by
    /// this app on their behalf — the relay refuses a receipt without it, and that refusal
    /// is the correct outcome of not ticking the box.
    var ageConfirmed = false

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
        makeClient: @escaping @Sendable (String) -> InviteClient? = { relay in
            InviteClient(relayURLString: relay, transport: URLSessionHTTPTransport())
        }
    ) {
        self.environment = environment
        self.makeClient = makeClient
        if let initialLink {
            linkText = initialLink.absoluteText
            adopt(initialLink)
        }
    }

    // MARK: - Reading the link

    private func linkTextChanged() {
        let parsed = InviteLink.parse(linkText)
        // The same link re-parsed is not a change: the text field reports one on every
        // keystroke, and re-adopting would cancel a policy fetch that is already in flight
        // and start it again, for ever, while the reader looks at a spinner.
        guard parsed != link else { return }
        adopt(parsed)
    }

    private func adopt(_ parsed: InviteLink?) {
        policyTask?.cancel()
        link = parsed
        policy = nil
        error = nil
        ageConfirmed = false
        alreadyJoined = nil
        guard let parsed else {
            isReadingPolicy = false
            step = .needsLink
            return
        }
        step = .reviewing
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

    // MARK: - Whether the button can be pressed

    /// Whether everything this join needs has been supplied.
    var canJoin: Bool {
        guard step == .reviewing, link != nil else { return false }
        if alreadyJoined != nil { return true }
        if identity == .existing, (try? PrivateKey(nsec: nsec.trimmingCharacters(in: .whitespacesAndNewlines))) == nil {
            return false
        }
        // An attestation the relay requires is the reader's to make, so the button waits
        // for it rather than the relay refusing after the fact — but only when the terms
        // have not already been accepted elsewhere. A handoff carrying a receipt has been
        // through this screen's equivalent in a browser.
        if link?.policyReceipt == nil, policy?.ageAttestationRequired == true, !ageConfirmed {
            return false
        }
        return true
    }

    /// What the button says. Named here rather than in the view because the *operation*
    /// changes with the state, not just the wording.
    var actionTitle: String {
        if alreadyJoined != nil { return "Open" }
        return step == .joining ? "Joining…" : "Join"
    }

    // MARK: - Doing it

    /// Runs the join, reporting into ``error`` and leaving the screen up if it fails.
    func submit() async {
        guard canJoin, let link else { return }
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

        step = .joining
        defer { if step == .joining { step = .reviewing } }

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
        }
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

    // MARK: - Saying what happened

    /// Turns a refusal into a sentence naming what the reader can do about it.
    ///
    /// The relay's own strings are never shown. `invite_exhausted` tells someone who cannot
    /// mint an invite nothing they can act on; "ask whoever invited you for a new link"
    /// does.
    static func message(for error: InviteError) -> String {
        invitationMessage(for: error) ?? exchangeMessage(for: error)
    }

    /// The invitation itself is no good. Every one of these ends in the same place — this
    /// link will not work again, ask for another — so they are grouped.
    private static func invitationMessage(for error: InviteError) -> String? {
        switch error {
        case .expired:
            "This invite has expired. Ask whoever invited you for a new link."
        case .exhausted:
            "This invite has already been used as many times as it allows. Ask for a new link."
        case .invalidCode:
            "This relay doesn't recognise that invite."
        case .policyRequired:
            "This community's terms have to be accepted before joining, and this link's "
                + "acceptance is no longer current. Open the invite link again."
        case .policyNotAccepted:
            "This community's terms changed while you were reading them. Open the invite "
                + "link again."
        case .noPolicyConfigured:
            "This community has no terms to accept."
        default:
            nil
        }
    }

    /// The invitation may be perfectly good; the conversation with the relay is what did
    /// not complete. These are the ones where trying again is the right advice.
    private static func exchangeMessage(for error: InviteError) -> String {
        switch error {
        case .rateLimited:
            "Too many attempts. Wait a minute and try again."
        case .unreachable:
            "Couldn't reach that relay. Check your connection and try again."
        case .invalidRelayURL:
            "That link doesn't name a relay Hive can connect to."
        case let .httpStatus(status):
            "The relay refused the invite (HTTP \(status))."
        default:
            "The relay's answer wasn't something Hive could read."
        }
    }

    // MARK: - Copy

    static let blurb =
        "An invite link is how you get into a community that doesn't already know you. "
            + "Paste one here, or open it from your browser."

    /// The one thing a reader has to understand before a fresh key is created for them —
    /// the same warning the Flutter client gives at the same moment
    /// (`invite_join_sheet.dart:82`).
    static let newIdentityWarning =
        "A new key is created for this community, and this phone is the only copy of it. "
            + "Back it up from your account screen once you're in."

    static let existingIdentityBlurb =
        "The community will see this key's public identity. Use a new one if you'd rather "
            + "it not be linked to where else you use it."
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
