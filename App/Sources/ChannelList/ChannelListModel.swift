import BuzzKit
import GRDB
import Observation

/// Drives ``ChannelListView`` from a live observation of the store.
///
/// One pattern, shared with ``ChannelTimelineModel``: a `ValueObservation` over
/// the `event`/`outbox` region (``DatabaseSignal``) re-fires on every relevant
/// commit, and each fire re-reads `store.channelList()` — BuzzKit's public,
/// deletion-aware, outbox-unioned query. SwiftUI reads plain properties; the model
/// never keeps a second list to fall out of step.
///
/// Rosters are deliberately *not* read here. ``EntityDirectoryModel`` already reads
/// every channel's members in one `directorySnapshot()`, and the sidebar's presence
/// marker takes them from the resolver — so the sidebar derives a roster once per
/// commit, not twice.
/// What the sidebar draws for its conversations, decided by whether the relay has
/// answered for this identity **this launch** rather than by what the store holds.
enum ChannelDirectorySurface: Equatable {
    /// No complete signed answer yet. No conversation row may be drawn.
    case connecting
    /// An answer landed, and the rows are that answer.
    case conversations
    /// The attempt finished without an answer and the grace period is over.
    case unreachable
}

@MainActor
@Observable
final class ChannelListModel {
    /// Channels, most-recently-active first, messageless last — the order
    /// `channelList()` already returns.
    ///
    /// Read directly only by the things that resolve a *name* — the `#channel` map and
    /// ``EntityNames`` — for which a cached channel is a perfectly good answer. What the
    /// sidebar may *list* is ``visibleChannels``.
    private(set) var channels: [ChannelListRow] = []
    /// Whether the relay has answered for this identity this launch, and so whether the
    /// sidebar may list conversations at all.
    private(set) var surface: ChannelDirectorySurface = .connecting
    /// True once the first snapshot has been applied, so the view can tell "empty"
    /// from "not loaded yet".
    private(set) var hasLoaded = false
    /// The threads holding replies the reader has not seen, newest first — what the
    /// Threads shortcut counts, before the device's own read marks are subtracted.
    ///
    /// The roots rather than a number, because the number is not this list's length: a
    /// thread already opened on this device is struck off by ``ThreadReadMarks``, which
    /// lives in `UserDefaults` and so cannot be part of the store's read.
    private(set) var unreadThreads: [UnreadThread] = []

    private let store: BuzzEventStore
    /// The local identity, so a channel's own posts are excluded from its unread
    /// count. `nil` degrades to counting every author (keyless fallback).
    private let selfPubkey: String?

    /// How long the relay has to answer before the sidebar says it could not be reached.
    /// Injected so a test does not spend it — the same reason ``PresenceHeartbeat`` and
    /// ``SyncEngine`` take their sleeps.
    private let answerDeadline: Duration
    /// The one armed deadline, held so an answer can cancel it.
    private var deadline: Task<Void, Never>?

    init(
        store: BuzzEventStore,
        selfPubkey: String? = nil,
        answerDeadline: Duration = ChannelListModel.defaultAnswerDeadline
    ) {
        self.store = store
        self.selfPubkey = selfPubkey
        self.answerDeadline = answerDeadline
        channels = (try? store.channelList(selfPubkey: selfPubkey)) ?? []
        unreadThreads = (try? store.unreadThreads(selfPubkey: selfPubkey)) ?? []
        hasLoaded = true
    }

    /// The conversations the sidebar may list.
    ///
    /// Empty until the relay has answered, because a cached row is a row nothing has
    /// verified: the store keeps a channel's metadata and history after the channel is
    /// deleted elsewhere, which is what put deleted channels on screen for a moment on
    /// every cold launch. Computed rather than a second stored list — the model keeps one
    /// list, so there is nothing here to fall out of step with ``channels``.
    var visibleChannels: [ChannelListRow] {
        surface == .conversations ? channels : []
    }

    /// Consumes the engine's directory verdicts until cancelled. Attach with `.task`.
    ///
    /// # Why the model reads the stream and the view does not
    ///
    /// This was a `.task(id: status)` in the view, and that was wrong twice over. A view
    /// *samples* — SwiftUI compares the id at body evaluation, and two verdicts delivered in
    /// one main-actor turn are one body pass with only the second value. The engine emits
    /// exactly that pair: ``SyncEngine`` sets its verdict at the end of a fetch and, when a
    /// refresh was requested while that one was in flight, moves straight back to `.checking`
    /// microseconds later. A dropped `.cachedFallback` costs the reader the recovery screen;
    /// a dropped `.authoritative` leaves the sidebar on placeholder rows forever with the
    /// answer already committed to the store, and nothing on that surface to press. A verdict
    /// is not something the view layer may miss, so it is not the view layer that reads it.
    nonisolated func trackDirectory(of engine: SyncEngine) async {
        for await status in await engine.channelDirectoryStatuses() {
            let snapshot = status == .authoritative ? readSnapshot() : nil
            await adopt(status, snapshot: snapshot)
        }
    }

    /// Folds one verdict into what the sidebar draws.
    ///
    /// - Parameter snapshot: the store read for an authoritative verdict, taken *off* this
    ///   actor by ``trackDirectory(of:)``. Passed in rather than read here so the whole
    ///   assignment stays one main-actor step — the read must not be the thing that splits
    ///   it, and `channelList()` is the heavy per-channel query.
    func adopt(_ status: ChannelDirectoryStatus, snapshot: Snapshot? = nil) {
        switch status {
        case .authoritative:
            deadline?.cancel()
            deadline = nil
            // Assigned *before* the surface flips, in one step. The verdict stream and the
            // store's own change observation are independent, so flipping first can draw
            // the pre-snapshot rows for a frame — precisely the flash this exists to end.
            let value = snapshot ?? readSnapshot()
            channels = value.channels
            unreadThreads = value.unreadThreads
            hasLoaded = true
            surface = .conversations
        case .checking, .cachedFallback:
            // A good answer keeps its list: a re-check does not blank it, and a *refresh*
            // that fails says so in a banner over it. And once the sidebar has said it
            // cannot reach the relay, only an answer takes that back — the engine cycles
            // between these two verdicts while it retries, and a reader watching Retry
            // flicker back to placeholder rows learns nothing from it.
            guard surface == .connecting else { return }
            armDeadline()
        }
    }

    /// Arms the one deadline, at most once.
    ///
    /// Measured from the first verdict rather than from a failure, which is the whole point:
    /// nothing bounds the signed directory request itself — `URLSession`'s default is a
    /// minute — so a relay that accepts the connection and never answers used to leave the
    /// reader on placeholder rows for that whole minute before a 2-second grace even began.
    /// A deadline from launch means the reader is told inside a known time whatever the
    /// transport does.
    private func armDeadline() {
        guard deadline == nil else { return }
        deadline = Task { [weak self, wait = answerDeadline] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.deadlineExpired()
        }
    }

    private func deadlineExpired() {
        guard surface == .connecting else { return }
        surface = .unreachable
    }

    /// The two reads the sidebar needs, together.
    struct Snapshot: Sendable {
        let channels: [ChannelListRow]
        let unreadThreads: [UnreadThread]
    }

    nonisolated func readSnapshot() -> Snapshot {
        Snapshot(
            channels: (try? store.channelList(selfPubkey: selfPubkey)) ?? [],
            unreadThreads: (try? store.unreadThreads(selfPubkey: selfPubkey)) ?? []
        )
    }

    /// How long the relay gets before the sidebar says it could not be reached.
    ///
    /// The reference client bounds a history fetch at eight seconds
    /// (`mobile/lib/shared/relay/relay_session.dart:185`); a directory that has not answered
    /// in that time is not answering. Long enough that a slow but working relay — three
    /// batched requests over a tailnet — is never called unreachable.
    static let defaultAnswerDeadline: Duration = .seconds(8)

    /// Consumes the observation until cancelled. Attach with SwiftUI's `.task`,
    /// which cancels it when the view goes away. `nonisolated` so the re-read runs
    /// off the main actor; only the property assignment hops back on.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                // One read. The second — a `mentions(for:)` batch over every row's newest
                // message id — went with the preview line it fed: the sidebar's mention
                // badge is now a column on this same query, counted over every unread
                // message rather than guessed from the newest one's `p` tags.
                let rows = (try? store.channelList(selfPubkey: selfPubkey)) ?? []
                // Ids and timestamps, not the thread list: the shortcut needs a number the
                // device's read marks can be subtracted from, and reading fifty threads'
                // worth of openers and replies per commit to draw one digit is work the
                // Threads screen does when it is actually open.
                let threads = (try? store.unreadThreads(selfPubkey: selfPubkey)) ?? []
                await apply(rows, unreadThreads: threads)
            }
        } catch {
            // The stream ends on cancellation or store teardown; the last snapshot
            // remains on screen rather than blanking.
        }
    }

    private func apply(_ rows: [ChannelListRow], unreadThreads threads: [UnreadThread]) {
        // The same guard ``EntityDirectoryModel/apply(_:)`` carries, and for the same
        // reason: the observation re-fires on *every* committed transaction, so a
        // reaction, a typing-unrelated read-state blob, or a message in a channel whose
        // row did not change would otherwise assign an equal list — and an equal
        // assignment still invalidates every view reading it. This view is the sidebar
        // and the root of the environment the whole app resolves names through, so that
        // is a global re-render pump. Covers every assigned property, `hasLoaded`
        // included, so the very first (empty) snapshot still lands.
        guard rows != channels || threads != unreadThreads || !hasLoaded else { return }
        channels = rows
        unreadThreads = threads
        hasLoaded = true
    }
}
