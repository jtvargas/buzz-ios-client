import BuzzKit
import Foundation
import Observation

/// Resolves the sync engine's newly inserted live messages through the Activity feed and
/// presents only the newest qualifying foreground banner.
///
/// # Why the whole banner lives here and not in a view
///
/// Drawing the card, playing the arrival haptic and starting the clock that takes it away were
/// all jobs for ``InAppNotificationHost``, and all three stopped happening while the reader had
/// a file open: SwiftUI does not run a view update for a tree that a full-screen presentation
/// has detached from the window. This object has no view lifetime, so it keeps running. The
/// full measurement is in ``InAppNotificationWindowController``.
@MainActor
@Observable
final class InAppNotificationModel {
    private(set) var current: InAppNotification?

    /// The overlay window the card is drawn in. Owned here because this is what drives it; the
    /// host only borrows it to report the scene and to take it down.
    let window: InAppNotificationWindowController

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?
    private let onOpen: (InAppNotificationRoute) -> Void
    private var isForeground: Bool
    private var visibleLocation: InAppNotificationLocation?
    /// The clock that retires the card on screen, cancelled whenever that card changes.
    private var retirement: Task<Void, Never>?

    nonisolated static let feedLimit = 100

    /// How long a card stays up on its own.
    private static let visibleDuration = Duration.seconds(5)

    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        isForeground: Bool,
        visibleLocation: InAppNotificationLocation?,
        window: InAppNotificationWindowController = InAppNotificationWindowController(),
        onOpen: @escaping (InAppNotificationRoute) -> Void = { _ in }
    ) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        self.isForeground = isForeground
        self.visibleLocation = visibleLocation
        self.window = window
        self.onOpen = onOpen
    }

    nonisolated func run() async {
        let insertions = await engine.liveMessageInsertions()
        for await eventIDs in insertions {
            let feed = (try? store.activityFeed(
                selfPubkey: selfPubkey,
                limit: Self.feedLimit
            )) ?? []
            await apply(feed, insertedEventIDs: Set(eventIDs))
        }
    }

    func setForeground(_ active: Bool) {
        guard active != isForeground else { return }
        isForeground = active
        if !active {
            show(nil)
        }
    }

    func setVisibleLocation(_ location: InAppNotificationLocation?) {
        visibleLocation = location
        if current?.location.isVisible(in: location) == true { dismissCurrent() }
    }

    func dismissCurrent() {
        show(nil)
    }

    private func apply(_ feed: [ActivityEntry], insertedEventIDs: Set<String>) {
        guard isForeground else {
            InAppNotificationDiagnostics.record("apply outcome=no-candidate reason=background")
            return
        }

        var consideredEntry = false
        for entry in feed where insertedEventIDs.contains(entry.latest.id) {
            consideredEntry = true
            let notification = InAppNotification(entry: entry)
            let isVisible = notification.location.isVisible(in: visibleLocation)
            let verdict = "id=\(notification.id) unreadCount=\(entry.unreadCount) " +
                "qualifies=\(notification.qualifies) isVisible=\(isVisible)"

            guard entry.unreadCount > 0 else {
                InAppNotificationDiagnostics.record("apply outcome=suppressed-zero-unread \(verdict)")
                continue
            }
            guard notification.qualifies else {
                InAppNotificationDiagnostics.record("apply outcome=no-candidate \(verdict)")
                continue
            }
            guard !isVisible else {
                InAppNotificationDiagnostics.record("apply outcome=suppressed-visible \(verdict)")
                continue
            }

            InAppNotificationDiagnostics.record("apply outcome=shown \(verdict)")
            show(notification)
            return
        }

        if !consideredEntry {
            InAppNotificationDiagnostics.record("apply outcome=no-candidate reason=no-inserted-feed-entry")
        }
    }

    /// The one place `current` moves, and the reason it is the only one.
    ///
    /// Four things belong to the moment a card changes: it is drawn, the window is made
    /// touchable or not, the arrival is announced, and the clock that retires it is restarted.
    /// A view used to own the last two and get the cancellation of the clock for free from
    /// `.task(id:)`. Both are hand-held now, so they are kept in one function rather than
    /// spread across the callers — a window left interactive with no card in it is a
    /// full-screen touch target over the whole app, and a clock left running from the previous
    /// card retires this one early.
    private func show(_ notification: InAppNotification?) {
        // When both values are nil there cannot be a live retirement task: every path that
        // clears `current` cancels and clears it below. Keep this before cancellation so a
        // replay of the visible id cannot cancel that card's retirement without replacing it.
        guard notification?.id != current?.id else { return }
        current = notification
        retirement?.cancel()
        window.show(
            notification,
            open: { [weak self] notification in
                guard let self else { return }
                onOpen(notification.route)
                dismissCurrent()
            },
            dismiss: { [weak self] in self?.dismissCurrent() }
        )
        guard notification != nil else {
            retirement = nil
            return
        }
        HiveHaptics.play(.messageArrived)
        retirement = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent()
        }
    }
}
