import BuzzKit
import Foundation
import Observation

/// Drives the Later screen: the three lists, the actions that move a reminder between
/// them, and keeping the scheduled alerts in step with what is actually pending.
///
/// Reads are a live observation of the `reminder` projection, so a reminder set on another
/// device appears here without a refresh, and one completed there leaves.
@MainActor
@Observable
final class LaterModel {
    private(set) var pending: [ReminderRow] = []
    private(set) var completed: [ReminderRow] = []
    private(set) var archived: [ReminderRow] = []

    private let store: BuzzEventStore
    private let engine: SyncEngine
    private let scheduler: ReminderScheduler
    /// Resolves an author pubkey to the name an alert should say. Injected rather than
    /// read here so the model does not depend on the view's environment.
    private let authorName: (String) -> String

    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        scheduler: ReminderScheduler,
        authorName: @escaping (String) -> String
    ) {
        self.store = store
        self.engine = engine
        self.scheduler = scheduler
        self.authorName = authorName
    }

    /// The tabs, in the order the screen draws them. Named against the reminder statuses
    /// they show, which is the mapping the whole screen rests on:
    /// **In Progress = pending, Archived = cancelled, Completed = done.**
    enum Tab: String, CaseIterable, Identifiable {
        case inProgress = "In Progress"
        case archived = "Archived"
        case completed = "Completed"

        var id: String { rawValue }
    }

    func rows(for tab: Tab) -> [ReminderRow] {
        switch tab {
        case .inProgress: pending
        case .archived: archived
        case .completed: completed
        }
    }

    /// Observes the projection, refreshing all three lists on any change.
    ///
    /// One observation rather than three: they are three reads of one table, and a single
    /// signal keeps the counts on the tab bar consistent with the list under it.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let pending = (try? store.reminders(status: .pending)) ?? []
                let done = (try? store.reminders(status: .done)) ?? []
                let cancelled = (try? store.reminders(status: .cancelled)) ?? []
                await apply(pending: pending, done: done, cancelled: cancelled)
            }
        } catch {
            // The stream ends on cancellation or teardown; the last state stays.
        }
    }

    private func apply(pending: [ReminderRow], done: [ReminderRow], cancelled: [ReminderRow]) async {
        self.pending = pending
        completed = done
        archived = cancelled
        // Every change, because a change is exactly when the scheduled set can have gone
        // stale — including one that arrived from another device, which has no local
        // action behind it to hang the rescheduling off.
        await scheduler.reconcile(pending: pending, authorName: authorName)
    }

    // MARK: - Actions

    func complete(_ row: ReminderRow) async {
        scheduler.cancel(row.id)
        await engine.completeReminder(row)
    }

    func archive(_ row: ReminderRow) async {
        scheduler.cancel(row.id)
        await engine.cancelReminder(row)
    }

    /// Moves a reminder to a new time and keeps it pending — the clock button on a row.
    func snooze(_ row: ReminderRow, to due: Date) async {
        await engine.snoozeReminder(row, notBefore: Int64(due.timeIntervalSince1970))
        await scheduler.schedule(row, authorName: authorName(row.target?.authorPubkey ?? ""))
    }

    /// Puts a completed or archived reminder back into In Progress at a new time.
    func restore(_ row: ReminderRow, to due: Date) async {
        await snooze(row, to: due)
    }
}
