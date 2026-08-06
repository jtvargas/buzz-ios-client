import BuzzKit
import Foundation
import Observation

/// Resolves the sync engine's newly inserted live messages through the Activity feed and
/// presents only the newest qualifying foreground banner.
@MainActor
@Observable
final class InAppNotificationModel {
    private(set) var current: InAppNotification?

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let selfPubkey: String?
    private var isForeground: Bool
    private var visibleLocation: InAppNotificationLocation?

    nonisolated static let feedLimit = 100

    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        isForeground: Bool,
        visibleLocation: InAppNotificationLocation?
    ) {
        self.store = store
        self.engine = engine
        self.selfPubkey = selfPubkey
        self.isForeground = isForeground
        self.visibleLocation = visibleLocation
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
            current = nil
        }
    }

    func setVisibleLocation(_ location: InAppNotificationLocation?) {
        visibleLocation = location
        if current?.location.isVisible(in: location) == true { dismissCurrent() }
    }

    func dismissCurrent() {
        current = nil
    }

    private func apply(_ feed: [ActivityEntry], insertedEventIDs: Set<String>) {
        guard isForeground else { return }

        let newest = feed.lazy
            .filter { entry in
                entry.unreadCount > 0 && insertedEventIDs.contains(entry.latest.id)
            }
            .map(InAppNotification.init)
            .first { notification in
                notification.qualifies
                    && !notification.location.isVisible(in: visibleLocation)
            }
        if let newest { current = newest }
    }
}
