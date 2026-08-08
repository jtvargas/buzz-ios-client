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
/// The owner asked for communities not to mix, and the way this holds them is what stops
/// them mixing: **one list per community id**, in memory and on disk both, asked for by id
/// at every call. There is no "active" list, so there is no moment at which the wrong one
/// is loaded and no state to keep in step with the app's community switch.
///
/// That shape is a correction. The first version held one list plus the id it was loaded
/// for, and re-pointed on demand — which meant a call made while the app had no active
/// community (a launch, a switch, a signed-out frame) re-pointed it at *nothing* and
/// emptied it. The owner saw exactly that: a history that vanished at random. A dictionary
/// keyed by community cannot express the bug, because nothing is ever pointed anywhere.
///
/// A community's id is device-local and survives re-pairing the same relay — see
/// ``CommunityDirectory/add(_:)``, which adopts the existing id — so the history does too.
@MainActor
@Observable
final class RecentPlaces {
    /// Every community's places this session has touched, newest first within each.
    ///
    /// A cache over ``UserDefaults`` rather than the record of truth: a community absent
    /// here has not been *read* yet, never "has no history".
    private(set) var byCommunity: [Community.ID: [RecentPlace]] = [:]

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

    /// One community's places, newest first. Empty for a community with no history, and for
    /// the frame before the app has one at all.
    ///
    /// Reads through to storage on a miss and does **not** write the result back: a read
    /// that mutates could not be called from a `View`'s body without SwiftUI complaining,
    /// and this list is twelve entries — cheap enough that the cache is a convenience rather
    /// than a requirement.
    func places(in community: Community.ID?) -> [RecentPlace] {
        guard let community else { return [] }
        return byCommunity[community] ?? load(community)
    }

    /// Records a visit, moving an already-known place to the front rather than repeating it.
    ///
    /// `nil` for either argument is ignored outright — the reader standing in the sidebar
    /// rather than inside anything, or a frame before a community exists. Neither is news
    /// about any community's history, so neither touches one.
    func visit(_ location: InAppNotificationLocation?, in community: Community.ID?) {
        guard let community, let location, !location.channelID.isEmpty else { return }
        let place = RecentPlace(location)
        var updated = places(in: community).filter { $0.id != place.id }
        updated.insert(place, at: 0)
        let capped = Array(updated.prefix(Self.capacity))
        byCommunity[community] = capped
        save(capped, for: community)
    }

    /// The places whose conversation the sidebar still lists, for the community named.
    ///
    /// Checked against the live list rather than trusted, for the reason
    /// ``ConversationResume/resolved(among:)`` gives: a conversation can leave the sidebar
    /// while it is in here — a hidden direct message, a channel this key was removed from —
    /// and offering it is a row that navigates somewhere the sidebar says you cannot go.
    ///
    /// An **empty** sidebar is not that answer, though: it is the sidebar before its first
    /// read has landed, and filtering against it would blank the history every cold launch.
    /// So the check applies only once there is a list to check against.
    func resolved(among channels: [ChannelListRow], in community: Community.ID?) -> [RecentPlace] {
        let places = places(in: community)
        guard !channels.isEmpty else { return places }
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
    private func save(_ places: [RecentPlace], for community: Community.ID) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: Self.storageKey(for: community))
    }
}
