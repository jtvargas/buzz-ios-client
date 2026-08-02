import BuzzKit
import Foundation
import NostrCore
import Observation

/// Asks a host what it is, so a reader can see the community before agreeing to be in it.
///
/// # What this can honestly say
///
/// One thing, and it is worth saying: **a real Buzz relay answered at that host over TLS.**
/// That is the whole of ``isVerified``. It is not a claim that the invite is any good — the
/// only place that is settled is the claim itself — and it is not a claim about who runs the
/// community, which nothing here can check.
///
/// It cannot name the community either: a Buzz relay's information document carries the same
/// `"Buzz Relay"` for every deployment, on purpose (§ ``BuzzKit/RelayInfo``). The name on the
/// card comes from the host, through the same rule Buzz Desktop uses on the same relay, so
/// the phone and the laptop agree.
///
/// # Best effort, and never in the way
///
/// A host that never answers leaves the card unverified and changes nothing else. Nothing
/// waits on this and no button is gated on it: an operator running a relay behind something
/// that does not serve the document would otherwise be unable to add their own community.
@MainActor
@Observable
final class CommunityLookup {
    /// The relay currently being described, so the card can be shown for it and not for the
    /// half-typed address that replaced it.
    private(set) var relayURLString: String?
    /// True between asking and hearing, so the card reads as confirming rather than as blank.
    private(set) var isChecking = false
    /// Whether the host answered as a Buzz relay.
    private(set) var isVerified = false
    /// The community's own workspace icon, when its owner set one.
    private(set) var icon: RelayIcon?

    private let makeClient: @Sendable (String) -> RelayInfoClient?
    private let debounce: Duration
    private var task: Task<Void, Never>?

    /// - Parameter debounce: how long a relay has to stand still before it is asked anything.
    ///   Not cosmetic: `Add community`'s field is **typed into**, and every prefix of
    ///   `wss://relay.example` that has a host is a different host — so without this, typing
    ///   one address puts a request to a dozen partial hostnames on the wire. Tests pass
    ///   `.zero`.
    init(
        debounce: Duration = .milliseconds(350),
        makeClient: @escaping @Sendable (String) -> RelayInfoClient? = { relay in
            RelayInfoClient(relayURLString: relay, transport: URLSessionHTTPTransport())
        }
    ) {
        self.debounce = debounce
        self.makeClient = makeClient
    }

    /// The name to put over the card: the host's own, derived exactly as Desktop derives it.
    var name: String {
        relayURLString.map { CommunityIdentity.name(forRelay: $0) } ?? ""
    }

    /// Points the lookup at a relay, or at nothing.
    ///
    /// Re-pointing at the relay already described is a no-op — this is driven from a text
    /// field, and every keystroke inside an invite code names the same host. Without that
    /// guard a pasted code would fire a request per character and the card would flicker
    /// through `Checking…` for the length of it.
    func look(at relay: String?) {
        guard relay != relayURLString else { return }
        task?.cancel()
        relayURLString = relay
        icon = nil
        isVerified = false
        guard let relay, let client = makeClient(relay) else {
            isChecking = false
            return
        }
        // Set before the wait, not after it: the card is confirming from the moment the
        // address resolves, and a third of a second of blank card would read as an answer.
        isChecking = true
        let wait = debounce
        task = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            let info = try? await client.fetch()
            guard let self, !Task.isCancelled, self.relayURLString == relay else { return }
            self.isChecking = false
            guard let info else { return }
            // A plain Nostr relay answers this document too, and has no invite API at all.
            // Calling that a verified community would promise a join that cannot happen.
            self.isVerified = info.isBuzzRelay
            self.icon = info.communityIcon
        }
    }
}
