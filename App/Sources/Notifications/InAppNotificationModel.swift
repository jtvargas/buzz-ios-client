import BuzzKit
import Foundation
import Observation

/// Watches the local Activity feed and turns only newly observed foreground messages into
/// a small, bounded stream of banners.
@MainActor
@Observable
final class InAppNotificationModel {
    private(set) var current: InAppNotification?

    private let store: BuzzEventStore
    private let selfPubkey: String?
    private var hasBaseline = false
    private var isForeground: Bool
    private var visibleLocation: InAppNotificationLocation?
    private var queue: [InAppNotification] = []
    private var seenEventIDs: Set<String> = []
    private var seenEventOrder: [String] = []

    nonisolated static let feedLimit = 100
    nonisolated static let queueLimit = 4
    nonisolated static let seenLimit = 512
    nonisolated static let coalescingWindow = Duration.milliseconds(250)

    init(
        store: BuzzEventStore,
        selfPubkey: String?,
        isForeground: Bool,
        visibleLocation: InAppNotificationLocation?
    ) {
        self.store = store
        self.selfPubkey = selfPubkey
        self.isForeground = isForeground
        self.visibleLocation = visibleLocation
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.coalescedChanges(in: store.reader) {
                let feed = (try? store.activityFeed(
                    selfPubkey: selfPubkey,
                    limit: Self.feedLimit
                )) ?? []
                await apply(feed)
                try await Task.sleep(for: Self.coalescingWindow)
            }
        } catch {
            // Cancellation tears down the community-scoped observer and its queued banners.
        }
    }

    func setForeground(_ active: Bool) {
        guard active != isForeground else { return }
        isForeground = active
        if !active {
            current = nil
            queue.removeAll(keepingCapacity: true)
        }
    }

    func setVisibleLocation(_ location: InAppNotificationLocation?) {
        visibleLocation = location
        queue.removeAll { $0.location.isVisible(in: location) }
        if current?.location.isVisible(in: location) == true { dismissCurrent() }
    }

    func dismissCurrent() {
        current = queue.isEmpty ? nil : queue.removeFirst()
    }

    private func apply(_ feed: [ActivityEntry]) {
        let notifications = feed.map(InAppNotification.init)
        guard hasBaseline else {
            hasBaseline = true
            notifications.forEach { remember($0.id) }
            return
        }

        let new = notifications.filter { !seenEventIDs.contains($0.id) }
        notifications.forEach { remember($0.id) }
        guard isForeground else { return }

        // The feed is newest-first. Enqueue oldest-first so a burst is narrated in the
        // order it arrived rather than backwards.
        for notification in new.reversed()
        where notification.qualifies && !notification.location.isVisible(in: visibleLocation) {
            enqueue(notification)
        }
    }

    private func enqueue(_ notification: InAppNotification) {
        if current?.conversationID == notification.conversationID {
            current = notification
            return
        }
        queue.removeAll { $0.conversationID == notification.conversationID }
        queue.append(notification)
        if queue.count > Self.queueLimit {
            queue.removeFirst(queue.count - Self.queueLimit)
        }
        if current == nil { current = queue.removeFirst() }
    }

    private func remember(_ eventID: String) {
        guard seenEventIDs.insert(eventID).inserted else { return }
        seenEventOrder.append(eventID)
        if seenEventOrder.count > Self.seenLimit {
            let overflow = seenEventOrder.count - Self.seenLimit
            for expired in seenEventOrder.prefix(overflow) { seenEventIDs.remove(expired) }
            seenEventOrder.removeFirst(overflow)
        }
    }
}
