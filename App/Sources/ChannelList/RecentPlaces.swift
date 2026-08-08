import BuzzKit
import Foundation
import Observation

/// One place the reader has been: a conversation, or a thread inside one.
///
/// The same two cases ``InAppNotificationLocation`` already names, in a form that can be
/// written to disk. A separate type rather than a `Codable` conformance on that enum,
/// because what a *notification* points at and what a history *remembers* are free to
/// drift — and because an enum's synthesised coding keys are its case names, which would
/// make renaming a case a silent loss of everybody's history.
struct RecentPlace: Codable, Hashable, Identifiable {
    let channelID: String
    /// The thread's root, when the place is a thread rather than the channel around it.
    let rootID: String?

    /// A channel and a thread inside it are two places, and both can be in the list at
    /// once — which is what the owner's reference shows.
    var id: String {
        guard let rootID else { return channelID }
        return "\(channelID)/\(rootID)"
    }

    var isThread: Bool { rootID != nil }

    var location: InAppNotificationLocation {
        guard let rootID else { return .channel(channelID) }
        return .thread(channelID: channelID, rootID: rootID)
    }

    init(_ location: InAppNotificationLocation) {
        switch location {
        case let .channel(channelID):
            self.channelID = channelID
            rootID = nil
        case let .thread(channelID, rootID):
            self.channelID = channelID
            self.rootID = rootID
        }
    }
}

/// The last twelve places this reader visited **in one community**, newest first.
///
/// # Why it is not ``ConversationResume``
///
/// That type holds one slot, is filled on the way *out*, and is deliberately not
/// persisted: it exists to explain a gesture, and a highlight pointing at yesterday is a
/// claim about the reader's memory. This is the opposite on all three counts. It is a list
/// the reader *opens on purpose*, so it is filled on arrival, and a history that empties
/// every launch is not a history — the question it answers ("where was I working?") is at
/// its most useful exactly when the app has been away.
///
/// # One community, structurally
///
/// The owner asked for communities not to mix. Two things enforce it, and neither is a
/// filter anyone has to remember to apply. The storage key carries the community's id, so
/// the twelve slots are *per community* — reading a dozen channels in one cannot evict the
/// other's history. And the in-memory list carries the community it was loaded for, so a
/// read taken with a different id answers empty rather than answering with the wrong
/// community's rows. The failure mode of a desync is a popover that is briefly empty,
/// which is the direction a mistake here should fail in.
///
/// A community's id is device-local and survives re-pairing the same relay — see
/// ``CommunityDirectory/add(_:)``, which adopts the existing id — so the history does too.
@MainActor
@Observable
final class RecentPlaces {
    /// The active community's places, newest first. Empty before a community is named.
    private(set) var places: [RecentPlace] = []
    /// The community ``places`` was loaded for.
    private(set) var community: Community.ID?

    /// The owner's number.
    static let capacity = 12

    /// The `UserDefaults` key holding one community's list.
    ///
    /// Pinned by a test, for the reason ``StarredConversations/storageKey`` is: renaming it
    /// silently discards the history every existing install has built, and nothing else
    /// would catch it.
    static func storageKey(for community: Community.ID) -> String {
        "home.recent.places.\(community.uuidString)"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the list at a community, loading what that community already has.
    ///
    /// Idempotent, and called by both the read and the write below rather than from a
    /// lifecycle hook — the same reasoning as ``ConversationResume``'s: a value observed
    /// where it is *used* cannot be missed by a route nobody remembered to instrument.
    func use(_ community: Community.ID?) {
        guard community != self.community else { return }
        self.community = community
        places = community.map(load) ?? []
    }

    /// Records a visit, moving an already-known place to the front rather than repeating it.
    ///
    /// `nil` is the reader standing in the sidebar rather than inside anything, which is not
    /// a place and is what this is handed every time they back out of one.
    func visit(_ location: InAppNotificationLocation?, in community: Community.ID?) {
        use(community)
        guard let community, let location, !location.channelID.isEmpty else { return }
        let place = RecentPlace(location)
        var updated = places.filter { $0.id != place.id }
        updated.insert(place, at: 0)
        places = Array(updated.prefix(Self.capacity))
        save(for: community)
    }

    /// The places whose conversation the sidebar still lists, for the community named.
    ///
    /// Checked against the live list rather than trusted, for the reason
    /// ``ConversationResume/resolved(among:)`` gives: a conversation can leave the sidebar
    /// while it is in here — a hidden direct message, a channel this key was removed from —
    /// and offering it is a row that navigates somewhere the sidebar says you cannot go.
    ///
    /// The community is named again here rather than assumed: a read racing a switch would
    /// otherwise be the one way a foreign row could reach the screen.
    func resolved(among channels: [ChannelListRow], in community: Community.ID?) -> [RecentPlace] {
        guard community == self.community else { return [] }
        let listed = Set(channels.map(\.id))
        return places.filter { listed.contains($0.channelID) }
    }

    /// Where a navigation stack is: the thread on top, else the conversation under it.
    ///
    /// Static, and shared by both tabs' stacks, because the two have to agree about what
    /// counts as being somewhere. They hold the same two pieces of state for the same
    /// reasons, and a second copy of this rule is a second answer waiting to happen.
    static func location(
        path: [ConversationRoute],
        openedThread: ThreadRoute?
    ) -> InAppNotificationLocation? {
        if let openedThread {
            return .thread(channelID: openedThread.channel, rootID: openedThread.root)
        }
        return path.last.map { .channel($0.channel.id) }
    }

    private func load(_ community: Community.ID) -> [RecentPlace] {
        guard let data = defaults.data(forKey: Self.storageKey(for: community)),
              let stored = try? JSONDecoder().decode([RecentPlace].self, from: data)
        else {
            // A value written by some future version of this app with a different shape
            // reads as nothing, and the reader starts with an empty history — rather than
            // this trapping at launch on a failed decode.
            return []
        }
        return Array(stored.prefix(Self.capacity))
    }

    /// Written on every visit. There is no later moment at which a history is committed,
    /// and an app killed from the switcher must not lose where its owner just was.
    private func save(for community: Community.ID) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: Self.storageKey(for: community))
    }
}
