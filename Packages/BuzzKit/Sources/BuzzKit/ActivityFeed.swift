import Foundation
import GRDB
import NostrCore

/// What kind of attention an activity row is asking for.
///
/// The same four the relay's own feed uses (`crates/buzz-db/src/feed.rs`) and the same four
/// the desktop and Flutter clients render, so a row means the same thing on every client
/// someone opens. Hive computes them locally rather than asking the relay for a categorised
/// feed: every event this list can show is already in the log, the categories are a function
/// of kind and tags, and a local read updates live off the same `ValueObservation` the rest
/// of the app runs on instead of going stale between polls.
///
/// Ordered by how loudly each one asks. ``ActivityCategory/priority`` is derived from the
/// declaration order, which is what settles the label when one conversation collects events
/// from more than one category.
public enum ActivityCategory: String, Sendable, Hashable, CaseIterable, Codable {
    /// Something is waiting on a decision from you: a workflow approval, a reminder the
    /// relay is holding. Loudest, because it does not resolve on its own.
    case needsAction
    /// Someone named you. The reason most people open this screen.
    case mention
    /// An agent you asked for work reported back — a job accepted, progressed, finished,
    /// or failed.
    case agentActivity
    /// Traffic in a conversation you are part of that did not name you: a direct message,
    /// a reply under a message of yours.
    case activity

    /// How loudly this category asks, lowest first. Derived from declaration order so the
    /// two cannot drift: reordering the cases above reorders this.
    public var priority: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// The word the row wears. Sentence case, matching every other label in the app.
    public var label: String {
        switch self {
        case .needsAction: "Action"
        case .mention: "Mention"
        case .agentActivity: "Agent"
        case .activity: "Activity"
        }
    }
}

/// One row in the Activity list: **a conversation, not a message**.
///
/// This is the whole difference between Hive's Activity tab and the Flutter client's. That
/// one renders one row per event, which is why nine replies from the same agent in the same
/// thread read as nine separate things to deal with. Desktop groups by conversation
/// (`desktop/src/features/home/lib/inbox.ts`, `buildInboxItems`) and shows a count; this
/// does the same, so a busy thread costs one row and one glance.
///
/// ``latest`` is the event the row draws — the newest in the conversation — while ``id`` is
/// the conversation's own stable identity. They differ on purpose: a new reply advances the
/// drawn event but must not change the row's identity, or SwiftUI tears the row down and
/// rebuilds it (losing its position, its swipe state, and any animation in flight) every
/// time someone types.
public struct ActivityEntry: Sendable, Hashable, Identifiable {
    /// Stable conversation identity, and the row's `id`: the NIP-10 root for a threaded
    /// message, the channel id for a direct message, the event's own id for a top-level
    /// message with no thread. Does not move when a new event arrives.
    public let id: String
    /// The loudest category among the events in this conversation.
    public let category: ActivityCategory
    /// Every category present, so a row that is both a mention and an approval can say so
    /// and can match either filter. Sorted by priority, `category` first.
    public let categories: [ActivityCategory]
    /// The channel this happened in, `nil` only for an event that carries no `h` tag.
    public let channelID: String?
    /// The channel's name as the roster knows it, empty when it is not cached yet.
    public let channelName: String
    /// Whether ``channelID`` names a direct-message channel, which the row titles by person
    /// rather than by channel.
    public let isDirectMessage: Bool
    /// The newest event in the conversation — what the row draws.
    ///
    /// # Where this diverges from desktop, and why
    ///
    /// Desktop's representative is the **oldest unread**, falling back to the newest only
    /// when a conversation is fully read (`desktop/src/features/home/lib/inbox.ts:614-629`,
    /// `unreadItems[0] ?? latestItem`). It draws that event *and* lands on it, which is one
    /// good idea and one bad one wearing the same field. Landing on the oldest unread is
    /// right — you want to resume where you stopped. Drawing it is not: these rows are
    /// sorted by newest activity, so a row showing text from four hours ago would sit above
    /// fresher rows with a timestamp that disagrees with its own body.
    ///
    /// So Hive draws the newest, and takes the landing question separately — see
    /// ``isUnread``, which is what the screen uses to choose where a thread opens. Landing
    /// on a *specific* older message is not offered here because the app cannot do it yet:
    /// that is the parked message-deep-link work (`parked/message-deeplink`), and a field
    /// carrying an event nothing can navigate to would be a promise this type cannot keep.
    public let latest: ActivityEvent
    /// How many events in this conversation are behind this row. `1` for a row that
    /// collapsed nothing, and the row draws no count in that case.
    public let eventCount: Int
    /// How many of those are unread against the NIP-RS read frontier for the channel.
    /// Zero when everything has been seen; own posts never count.
    public let unreadCount: Int
    /// The thread this conversation is, when it is one. `nil` for a top-level message or a
    /// direct message, which open the channel rather than a thread.
    public let rootID: String?

    public init(
        id: String,
        category: ActivityCategory,
        categories: [ActivityCategory],
        channelID: String?,
        channelName: String,
        isDirectMessage: Bool,
        latest: ActivityEvent,
        eventCount: Int,
        unreadCount: Int,
        rootID: String?
    ) {
        self.id = id
        self.category = category
        self.categories = categories
        self.channelID = channelID
        self.channelName = channelName
        self.isDirectMessage = isDirectMessage
        self.latest = latest
        self.eventCount = eventCount
        self.unreadCount = unreadCount
        self.rootID = rootID
    }

    /// Whether this row matches a category filter — asked of every category present, not
    /// only the loudest, so an approval that also names you appears under Mentions.
    public func matches(_ category: ActivityCategory) -> Bool {
        categories.contains(category)
    }

    /// True when anything here has not been seen — and, on a threaded row, what decides
    /// whether opening it lands on the newest reply or on the message that started it.
    /// See ``latest``.
    public var isUnread: Bool { unreadCount > 0 }
}

/// The one event an ``ActivityEntry`` draws, with its author already resolved.
///
/// Resolved in the read rather than by the view: the alternative is a per-row profile
/// lookup on the main actor while the list scrolls, which is the shape that makes a feed
/// stutter. `authorName` falls back to a short npub the same way ``EntityNames`` does, so a
/// row never renders a bare 64-character hex string.
public struct ActivityEvent: Sendable, Hashable, Identifiable {
    /// The event id — what a tap navigates to.
    public let id: String
    /// The signer.
    public let pubkey: String
    /// The author's display name, or a shortened key when no profile is cached.
    public let authorName: String
    /// The author's avatar URL, `nil` when they have none.
    public let authorPicture: String?
    /// The raw Nostr kind, which is what decides an agent event's headline.
    public let kind: Int
    /// The event's text, uncut. Cutting is the row's business — it knows its own width.
    public let content: String
    /// Unix seconds.
    public let createdAt: Int64

    public init(
        id: String,
        pubkey: String,
        authorName: String,
        authorPicture: String?,
        kind: Int,
        content: String,
        createdAt: Int64
    ) {
        self.id = id
        self.pubkey = pubkey
        self.authorName = authorName
        self.authorPicture = authorPicture
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
    }
}

// MARK: - Kinds

/// Which Nostr kinds land in which category.
///
/// Lifted from the relay's own feed SQL so the four lists cannot drift from what desktop
/// shows for the same log: `crates/buzz-db/src/feed.rs` — `query_feed_mentions` (line 106),
/// `query_feed_needs_action` (line 191), `query_feed_activity` (line 265).
///
/// Deliberately narrower than the relay in one place: the relay's mention list also carries
/// the Buzz Git kinds (1618–1633) and forum kinds, which Hive has no surface for yet. A row
/// that cannot be opened is worse than no row, so they are held here, named, rather than
/// left out silently — adding the screen is what should add the kind.
public enum ActivityKinds {
    /// Kinds where a `p` tag naming you is a mention.
    public static let mention: Set<Int> = [
        9, // channel message
        40002, // channel message v2
        1, // text note
        45001, // forum post
        45003, // forum comment
    ]

    /// Kinds that are asking you for something, when tagged with your pubkey.
    public static let needsAction: Set<Int> = [
        46010, // workflow approval requested
        40007, // relay-held reminder
    ]

    /// Agent job lifecycle, when tagged with your pubkey. The relay's feed SQL lists only
    /// request/progress/result; the three terminal kinds are included here because an
    /// agent's job *failing* is the update most worth surfacing, and leaving it out is
    /// what makes a job look like it is still running forever.
    public static let agentActivity: Set<Int> = [
        43001, // job request
        43002, // job accepted
        43003, // job progress
        43004, // job result
        43005, // job cancelled
        43006, // job failed
    ]

    /// Kinds not yet shown, and why. Named rather than omitted so the next person adding
    /// a Buzz Git or forum screen finds the list instead of rediscovering it.
    ///
    /// Buzz Git: 1618 pull request, 1619 PR update, 1621 issue, 1630–1633 status.
    public static let unsurfaced: Set<Int> = [1618, 1619, 1621, 1630, 1631, 1632, 1633]

    /// Every kind the feed reads, in one set for the SQL `IN` clause.
    public static let all: Set<Int> = mention.union(needsAction).union(agentActivity)

    /// The category a kind implies on its own, before tags are considered. `nil` for a
    /// plain message, whose category depends on whether it names you and where it sits.
    public static func category(forKind kind: Int) -> ActivityCategory? {
        if needsAction.contains(kind) { return .needsAction }
        if agentActivity.contains(kind) { return .agentActivity }
        return nil
    }

    /// What each kind is called on a row, in place of a bare category label.
    ///
    /// A table rather than a `switch` so the mapping is data — the ten arms were a
    /// cyclomatic-complexity violation, and a lookup is also the shape that can be compared
    /// against the other clients' maps at a glance. Matches desktop's `feedHeadline`
    /// (`desktop/src/features/home/lib/inbox.ts:162-203`) kind for kind, so the same event
    /// is called the same thing wherever it is read.
    static let headlines: [Int: String] = [
        43001: "Job requested",
        43002: "Job accepted",
        43003: "Progress update",
        43004: "Job result",
        43005: "Job cancelled",
        43006: "Job failed",
        46010: "Approval requested",
        40007: "Reminder",
        45001: "Forum post",
        45003: "Forum reply",
    ]

    /// The headline an agent or workflow event wears in place of a category label. `nil` for
    /// a plain message, whose category label already says everything there is to say.
    public static func headline(forKind kind: Int) -> String? {
        headlines[kind]
    }
}
