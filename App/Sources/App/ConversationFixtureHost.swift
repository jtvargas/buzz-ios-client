#if DEBUG
import BuzzKit
import NostrCore
import SwiftUI

/// Opens the real conversation surface on a seeded throwaway store — the launch path
/// ``ConversationFixture`` describes.
///
/// # Why the seeding happens before the first body
///
/// The defect class this exists to catch turns on *when* content arrives relative to layout: a
/// `LazyVStack` rests at the bottom of a height it estimated from the rows it had measured at
/// that instant. So a fixture that seeded asynchronously would be testing its own timing rather
/// than the surface's. The store is opened and seeded synchronously in `init`, before any body
/// runs, which is the state a returning reader opens a cached conversation in.
///
/// ``ConversationFixture/Options/primed`` deliberately breaks that when a shape asks for it:
/// the first `n` messages are seeded up front and the rest land after the first layout, which
/// is a thread whose replies arrive a relay round trip later.
struct ConversationFixtureHost: View {
    private let options: ConversationFixture.Options
    private let store: BuzzEventStore?
    private let rootID: String?
    private let deferred: [NostrEvent]
    private let failure: String?

    private let sender = ConversationFixture.InertSender()
    private let opener = ConversationFixture.InertOpener()
    /// So the composer's `+` can be driven all the way to a thumbnail on a simulator
    /// with no relay in reach — see ``ConversationFixture/InertUploader``.
    private let uploader = ConversationFixture.InertUploader()
    /// Empty and never fed. Presence dots are not what this suite measures, and a real
    /// `PresenceStore` with nothing in it is what a conversation looks like before the roster
    /// answers — a state the app has to render anyway.
    private let presence = PresenceStore()

    init(options: ConversationFixture.Options) {
        self.options = options
        // Everything lands in locals first: the stored properties are `let`, so a partial
        // success followed by a throw could not reassign them.
        var openedStore: BuzzEventStore?
        var root: String?
        var held: [NostrEvent] = []
        var problem: String?
        do {
            let key = try PrivateKey()
            let store = try ConversationFixture.makeStore()
            let events = try ConversationFixture.events(for: options, key: key)
            let primed = min(options.primed, events.count)
            // A thread hangs off its first message; a channel has no root.
            root = options.surface == .thread ? events.first?.id : nil
            held = Array(events.dropFirst(primed))
            // Synchronous on purpose — see the note above. `ingest` is async, so this is the
            // one place the fixture blocks, and it blocks before the first frame rather than
            // during one.
            try Self.seed(Array(events.prefix(primed)), into: store)
            // Kicked off here rather than from a `.task`: a view-lifecycle hook made this
            // silently never run (measured — a `primed` shape rendered its opener and nothing
            // else for twelve seconds), and what the shape is *for* is content that lands after
            // the first layout, so the landing must not depend on the view at all.
            Self.land(held, into: store, after: .milliseconds(250))
            openedStore = store
        } catch {
            problem = String(describing: error)
        }
        store = openedStore
        rootID = root
        deferred = held
        failure = problem
    }

    /// Ingests a batch and waits for it, from a synchronous initialiser.
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

    var body: some View {
        Group {
            if let store {
                NavigationStack {
                    surface(store: store)
                }
            } else {
                // Surfaced rather than crashed: a fixture that traps reads in CI as a crash in
                // the app, which is the most expensive kind of false report.
                ContentUnavailableView {
                    Label("Fixture failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure ?? "unknown")
                }
                .accessibilityIdentifier("fixtureFailure")
            }
        }
    }

    @ViewBuilder
    private func surface(store: BuzzEventStore) -> some View {
        switch options.surface {
        case .thread:
            ThreadView(
                root: rootID ?? "",
                channel: ConversationFixture.channelID,
                store: store,
                sender: sender,
                opener: opener,
                presence: presence,
                uploader: uploader,
                selfPubkey: nil
            )
        case .channel:
            ChannelTimelineView(
                channel: ChannelListRow(
                    id: ConversationFixture.channelID,
                    name: "Fixture",
                    about: nil,
                    picture: nil,
                    isPrivate: false,
                    lastMessageAt: nil,
                    lastMessageSnippet: nil,
                    lastMessageAuthor: nil
                ),
                store: store,
                sender: sender,
                typing: NoopEphemeralPublisher(),
                readStateMarking: nil,
                opener: opener,
                presence: presence,
                uploader: uploader,
                selfPubkey: nil
            )
        }
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
}

/// Carries an error out of the detached seeding task. A `final class` because the closure
/// escapes; nothing else touches it once the semaphore has been signalled.
private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
#endif
