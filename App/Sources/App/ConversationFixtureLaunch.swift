#if DEBUG
import BuzzKit
import Foundation
import NostrCore

/// Building the conversation a fixture launch opens, exactly once.
///
/// Its own file so ``ConversationFixture`` stays about the *shapes* — what a conversation is
/// made of — while this is about the one-time work of turning a shape into a live store the
/// surface can be pointed at.
extension ConversationFixture {
    /// Everything one fixture launch needs.
    struct Prepared {
        let store: BuzzEventStore
        let sender: StoringSender
        /// The message a thread hangs off, or `nil` for a channel.
        let rootID: String?
    }

    /// Builds the conversation — or hands back the one already built.
    ///
    /// **Once per process, and that is load-bearing.** This used to run inside
    /// ``ConversationFixtureHost``'s `init`, and a SwiftUI `View`'s initialiser runs every time
    /// its parent's body does. A second pass called ``makeStore()`` again, which *deletes the
    /// sqlite file* and opens a new database at the same path. Nothing looked wrong: the
    /// surface keeps the first store (its model is `@State`, initialised once), and that store's
    /// connections still read the seeded conversation off the now-unlinked file. What broke was
    /// everything written afterwards — an own send landed in a database no reader would open
    /// again, so the composer's message never appeared and the failure read as a scroll defect.
    ///
    /// Caching the whole result rather than only the store also keeps the *conversation* fixed.
    /// Re-running the seeding would sign the same shape under fresh keys, and those are
    /// different events with different ids: the same eight messages, ingested twice, as sixteen.
    static func prepare(_ options: Options) throws -> Prepared {
        if let existing = preparation.value { return existing }
        // Two authors, so a shape holds both the row that names its writer and the rows that
        // stack under it — see ``authorRun``.
        let keys = [try PrivateKey(), try PrivateKey()]
        let store = try makeStore()
        let events = try events(for: options, keys: keys)
        let primed = min(options.primed, events.count)
        // Synchronous on purpose — see ``ConversationFixtureHost``. `ingest` is async, so this
        // is the one place the fixture blocks, and it blocks before the first frame.
        try seed(Array(events.prefix(primed)), into: store)
        // Kicked off here rather than from a `.task`: a view-lifecycle hook made this silently
        // never run (measured — a `primed` shape rendered its opener and nothing else for
        // twelve seconds), and what the shape is *for* is content that lands after the first
        // layout, so the landing must not depend on the view at all.
        land(Array(events.dropFirst(primed)), into: store, after: .milliseconds(250))
        land(try reaction(for: options, among: events), into: store, after: .milliseconds(options.reactAfter))
        let prepared = Prepared(
            store: store,
            // A third identity, so what the composer sends is not attributed to one of the
            // people already talking — which would fold it into their block and take away the
            // avatar and name a newly arrived message is supposed to carry.
            sender: StoringSender(store: store, signer: InMemorySigner(try PrivateKey())),
            rootID: options.surface == .thread ? events.first?.id : nil
        )
        preparation.value = prepared
        return prepared
    }

    /// The reaction a shape asked for, signed by somebody who is not in the conversation.
    ///
    /// A chip is the smallest thing that changes a row's height *where it stands* — nothing is
    /// added to the list, nothing is removed, nothing moves order — which is the change the
    /// scroll engine used to treat as an insertion and correct a reader in history for. It
    /// arrives through the store like any other event, so the surface learns about it the same
    /// way it learns about a peer's.
    ///
    /// A fourth key: a reaction from one of the two authors would be true to life, and the
    /// reader's own would be truer still, but neither changes what the row does and a separate
    /// identity keeps the shape's grouping (see ``ConversationFixture/authorRun``) untouched.
    private static func reaction(for options: Options, among events: [NostrEvent]) throws -> [NostrEvent] {
        guard let index = options.reactOn, events.indices.contains(index) else { return [] }
        let target = events[index]
        return [try NostrEvent.signed(
            kind: .reaction,
            content: "👍",
            tags: [["e", target.id], ["h", channelID]],
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + events.count * 60)),
            with: try PrivateKey()
        )]
    }

    /// Ingests a batch and waits for it, from a synchronous caller.
    private static func seed(_ events: [NostrEvent], into store: BuzzEventStore) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task.detached {
            do { _ = try await store.ingest(batch: events, phase: .backfill) } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    /// Lands the messages a `primed` shape held back, once the first layout has happened.
    ///
    /// Fire-and-forget on purpose: the store's own observation is what carries them into the
    /// view, which is exactly the path a reply arriving from the relay takes.
    private static func land(_ events: [NostrEvent], into store: BuzzEventStore, after delay: Duration) {
        guard !events.isEmpty else { return }
        Task.detached {
            try? await Task.sleep(for: delay)
            _ = try? await store.ingest(batch: events, phase: .live)
        }
    }

    /// A relay that answers a scrollback request with a page of older messages.
    ///
    /// It writes them through the store, exactly as ``SyncEngine/loadOlderHistory(channel:before:)``
    /// does, so the surface learns about them on the same observation and by the same path: the
    /// model re-reads, prepends, and announces. Nothing about the correction under test is
    /// simulated — only the relay is.
    ///
    /// Each page is stamped *before* everything already seeded, so it lands above the reader
    /// wherever they are, and each subsequent page before the one before it.
    actor HistoryPager: ChannelHistoryPaging {
        private let store: BuzzEventStore
        private let pageSize: Int
        private let delay: Duration
        private let key: PrivateKey
        private var served = 0
        private let pages: Int

        init(store: BuzzEventStore, pages: Int, pageSize: Int = 20, delayMilliseconds: Int) throws {
            self.store = store
            self.pages = pages
            self.pageSize = pageSize
            delay = .milliseconds(delayMilliseconds)
            key = try PrivateKey()
        }

        func loadOlderHistory(channel: String, before _: WindowCursor) async throws -> SyncEngine.OlderHistoryPage {
            guard served < pages else { return SyncEngine.OlderHistoryPage(hasMore: false, ingested: 0) }
            // The round trip. Without it the page is committed inside the same turn as the
            // request and never lands under a moving finger, which is the whole shape.
            try? await Task.sleep(for: delay)
            served += 1
            let events = try (0 ..< pageSize).map { index in
                // Descending into the past, page by page, so page two sits above page one.
                let step = (served - 1) * pageSize + index
                return try NostrEvent.signed(
                    kind: .channelMessage,
                    content: "Older message \(pages * pageSize - step) from the relay",
                    tags: [["h", channel]],
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 - (step + 1) * 60)),
                    with: key
                )
            }
            let outcome = try await store.ingest(batch: events, phase: .backfill)
            return SyncEngine.OlderHistoryPage(hasMore: served < pages, ingested: outcome.inserted.count)
        }
    }

    /// Holds the built conversation for the life of the process. A reference box because a
    /// mutable `static var` of a `Sendable` type is what strict concurrency refuses; only the
    /// main actor ever reaches it, from a `View`'s initialiser.
    private final class PreparedBox: @unchecked Sendable {
        var value: Prepared?
    }

    private static let preparation = PreparedBox()

}

/// Carries an error out of the detached seeding task. A `final class` because the closure
/// escapes; nothing else touches it once the semaphore has been signalled.
private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
#endif
