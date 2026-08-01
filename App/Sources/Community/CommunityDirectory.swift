import Foundation

/// Every community on this device and which one is being read: the whole of the app's
/// multi-community state, as one value.
///
/// A value type rather than an object, for two reasons. It is what `@Observable` needs to
/// see a change — ``AppEnvironment`` holds one of these, and a mutation of a stored struct
/// is a change to the property holding it, so the switcher redraws without anything having
/// to publish. And every rule that can be wrong here — which community is active after a
/// removal, whether adding a relay twice makes two entries — becomes a function with no
/// dependencies, testable without a Keychain, a database or a screen.
///
/// Persistence is somebody else's job: see ``CommunityStorage``.
struct CommunityDirectory: Equatable, Sendable {
    private(set) var communities: [Community]
    /// Which community is being read, or `nil` when there are none.
    ///
    /// Kept in step with ``communities`` by every mutation here rather than repaired on
    /// read, so an id pointing at a community that no longer exists is not a state this
    /// type can be in. A directory *loaded* from disk can be in it — see
    /// ``init(communities:activeID:)``.
    private(set) var activeID: Community.ID?

    /// Builds a directory, repairing an active id that names nothing.
    ///
    /// Both other clients repair rather than reject: Flutter rewrites the stored id to the
    /// first community (`community_provider.dart:110-124`) and Desktop falls back to
    /// `communities[0]` on every read (`useCommunities.tsx`, `activeCommunity`). The
    /// difference here is that the repair happens once, on the way in, so nothing
    /// downstream has to keep re-deciding it.
    init(communities: [Community] = [], activeID: Community.ID? = nil) {
        self.communities = communities
        if let activeID, communities.contains(where: { $0.id == activeID }) {
            self.activeID = activeID
        } else {
            self.activeID = communities.first?.id
        }
    }

    /// The community being read, or `nil` on an install with none — a fresh phone, or one
    /// whose last community was just removed.
    var active: Community? {
        guard let activeID else { return nil }
        return communities.first { $0.id == activeID }
    }

    var isEmpty: Bool { communities.isEmpty }

    /// The community already on this device for `urlString`'s relay, if there is one.
    func community(forRelay urlString: String) -> Community? {
        communities.first { $0.isSameRelay(as: urlString) }
    }

    /// Adds a community, or adopts `community`'s identity into the one already on this
    /// relay. Returns the id that ended up in the list — the existing one on a match.
    ///
    /// The merge is deliberately narrow: the incoming record's owner pubkey is taken and
    /// nothing else is. A name the reader has since changed is theirs and survives
    /// re-pairing, and the storage two records name is never swapped, because the store
    /// file already on disk is the one holding that relay's history.
    @discardableResult
    mutating func add(_ community: Community) -> Community.ID {
        guard let index = communities.firstIndex(where: { $0.isSameRelay(as: community.relayURLString) })
        else {
            communities.append(community)
            if activeID == nil { activeID = community.id }
            return community.id
        }
        if let incomingOwner = community.ownerPubkeyHex {
            communities[index].ownerPubkeyHex = incomingOwner
        }
        return communities[index].id
    }

    /// Removes a community and returns it, so the caller can delete the key and the
    /// database it names. Returns `nil` when there was nothing to remove.
    ///
    /// Removing the last one is allowed, unlike Desktop — which refuses because a desktop
    /// window with no community has nothing to draw. A phone does: it has the onboarding it
    /// launched with. Refusing here would mean a Remove button that silently does nothing
    /// on the one install where the reader most means it, and Flutter's mobile client makes
    /// the same choice (`community_provider.dart:53-67`, which signs out instead).
    @discardableResult
    mutating func remove(_ id: Community.ID) -> Community? {
        guard let index = communities.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = communities.remove(at: index)
        if activeID == id {
            // The one after it, so removing several in a row walks forwards rather than
            // snapping back to the top of the list each time.
            activeID = communities[safe: index]?.id ?? communities.last?.id
        }
        return removed
    }

    mutating func rename(_ id: Community.ID, to name: String) {
        guard let index = communities.firstIndex(where: { $0.id == id }),
              let sanitised = CommunityIdentity.sanitised(name)
        else { return }
        communities[index].name = sanitised
    }

    /// Makes `id` the community being read. A no-op for an id this directory does not hold,
    /// so a stale row in a sheet cannot point the app at nothing.
    mutating func setActive(_ id: Community.ID) {
        guard communities.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Writes a record back over the one with the same id — how the owner pubkey is
    /// recorded once a community's engine has resolved its identity.
    mutating func update(_ community: Community) {
        guard let index = communities.firstIndex(where: { $0.id == community.id }) else { return }
        communities[index] = community
    }
}

private extension Array {
    /// The element at `index`, or `nil` past the end. Used by ``CommunityDirectory/remove(_:)``,
    /// where the index of the removed community is one past the end when it was the last.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
