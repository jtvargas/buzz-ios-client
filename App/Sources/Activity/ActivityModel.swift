import BuzzKit
import Foundation
import Observation

/// Drives ``ActivityView``: everything addressed to you, one row per conversation, live
/// from the store.
///
/// The same shape as ``ThreadsModel`` and for the same reasons — a `ValueObservation` over
/// the event region re-fires on each relevant commit and the read is taken again, off the
/// main actor, with nothing cached in between. That is what makes this screen the one place
/// a mention *arrives* rather than the place you go to check: the standing channel
/// subscription commits the event, the observation fires, the row appears.
///
/// # Why the filter is not in the read
///
/// The chip rail filters ``entries`` in the view, not in SQL. Deliberate: the whole feed is
/// a few dozen rows already bounded by the store's scan limit, so filtering it is a
/// predicate over an array rather than a database round trip — and changing chips then costs
/// nothing and cannot flash an empty list while a read is in flight. It also keeps every
/// chip's count truthful at the same instant, which is what lets the rail draw them.
@MainActor
@Observable
final class ActivityModel {
    /// Conversations with something addressed to you, most recent first.
    private(set) var entries: [ActivityEntry] = []
    /// The users each shown message mentions, so an `@`-token in a row's preview renders
    /// as the pill it is in the conversation rather than as raw text.
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    /// Identities and rosters, for the ``EntityNames`` this tab injects into its own stack.
    private(set) var directory: DirectorySnapshot = .empty
    /// The workspace's channels, for the same resolver and for the `#channel` map.
    private(set) var channels: [ChannelListRow] = []
    /// True once the first snapshot lands, so the view can tell "nothing addressed to you"
    /// from "not read yet". Without it the empty state flashes on every cold open.
    private(set) var hasLoaded = false

    private let store: BuzzEventStore
    private let selfPubkey: String?

    /// How many conversations the screen reaches back over.
    ///
    /// A cap rather than paging, the same call ``ThreadsModel/limit`` makes and for the
    /// same reason: this is a "what have I missed" list, and nobody browses the hundredth
    /// most recent thing that mentioned them — they search. Stated here rather than left
    /// implicit because a silently truncated list reads as a complete one.
    ///
    /// Note this bounds *conversations*, not events: the store scans considerably deeper
    /// (``BuzzKit/ActivityFeedRead/scanLimit``) precisely so that one busy thread cannot
    /// crowd out the other ninety-nine.
    nonisolated static let limit = 100

    init(store: BuzzEventStore, selfPubkey: String?) {
        self.store = store
        self.selfPubkey = selfPubkey
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let feed = (try? store.activityFeed(
                    selfPubkey: selfPubkey,
                    limit: Self.limit
                )) ?? []
                // One batched read over the whole page rather than one per row — the shape
                // the timeline and the Threads screen both use. A hundred rows is one `IN`
                // clause, not a hundred trips to the reader while the list is scrolling.
                let mentions = (try? store.mentions(for: feed.map(\.latest.id))) ?? [:]
                // The resolvers this tab has to inject into its own navigation stack, read
                // *here* rather than by two more models. See ``ActivityView`` for why this
                // tab needs them at all; the point of folding them into this observation is
                // that it already re-runs on every relevant commit, so these cost two reads
                // rather than two more `ValueObservation`s over the same tables.
                let directory = (try? store.directorySnapshot()) ?? .empty
                let channels = (try? store.channelList(selfPubkey: selfPubkey)) ?? []
                await apply(feed, mentions: mentions, directory: directory, channels: channels)
            }
        } catch {
            // Ends on cancellation or teardown; the last snapshot stays on screen.
        }
    }

    /// The users a message mentions, empty when it mentions none.
    func mentions(for id: String) -> [MentionRef] {
        mentionRefs[id].map { Array($0) } ?? []
    }

    /// The rows under a chip, in feed order.
    func entries(matching filter: ActivityFilter) -> [ActivityEntry] {
        entries.filter(filter.matches)
    }

    /// How many *unread* conversations sit under a chip — the number the chip wears.
    ///
    /// Conversations rather than events, so the badge counts the same things the list below
    /// it does. A chip reading 9 over a list of two rows is the Flutter client's bug stated
    /// in a different place, and it is the one number on this screen that has to agree with
    /// what is under it.
    func unreadCount(matching filter: ActivityFilter) -> Int {
        entries.lazy.filter { filter.matches($0) && $0.isUnread }.count
    }

    private func apply(
        _ feed: [ActivityEntry],
        mentions: [String: MentionRefList],
        directory: DirectorySnapshot,
        channels: [ChannelListRow]
    ) {
        // Equal values are not written back — the observation re-fires on every committed
        // transaction, and an `@Observable` setter notifies whether or not the value moved.
        // The directory is the one most worth guarding: a reaction landing anywhere in the
        // workspace fires this, and re-assigning an equal snapshot would invalidate every
        // view reading `EntityNames` beneath this tab.
        guard feed != entries
            || mentions != mentionRefs
            || directory != self.directory
            || channels != self.channels
            || !hasLoaded
        else { return }
        entries = feed
        mentionRefs = mentions
        self.directory = directory
        self.channels = channels
        hasLoaded = true
    }
}
