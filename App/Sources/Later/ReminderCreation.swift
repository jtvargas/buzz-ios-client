import BuzzKit
import Foundation

/// Setting a reminder from a conversation, in one place.
///
/// Both the channel and a thread offer "Remind Me" on the same sheet, and both have to do
/// the same four things in the same order: ask for notification permission, publish the
/// reminder, and schedule the alert. A second copy is a second place for the two to drift
/// — the same reasoning that made ``MessageActionsSheet`` one sheet rather than two.
///
/// The scheduler is constructed per call rather than injected: it holds no state of its
/// own, and `UNUserNotificationCenter.current()` is already the process-wide singleton
/// everything it does goes through.
///
/// It has **no default**, deliberately. A scheduler built with no arguments is one with the
/// app-wide notification switch left at its permissive default (``ReminderScheduler/init``), so
/// a default here would be a way to schedule an alert past a switch the reader has turned off,
/// available to anyone who forgot to pass one. Requiring it makes the compiler ask.
@MainActor
enum ReminderCreation {
    static func set(
        _ row: TimelineRow,
        channelID: String,
        due: Date,
        engine: SyncEngine,
        authorName: String,
        scheduler: ReminderScheduler
    ) async {
        // Asked here, at the moment someone has chosen a time, rather than at launch. A
        // permission prompt before anyone has asked for anything is the one most reliably
        // refused, and a refusal costs the alert for good.
        await scheduler.requestAuthorization()

        let target = ReminderTarget(
            eventID: row.id,
            channelID: channelID,
            preview: Reminders.preview(of: row.content),
            authorPubkey: row.pubkey
        )
        let notBefore = Int64(due.timeIntervalSince1970)
        guard let reminderID = await engine.setReminder(target: target, notBefore: notBefore) else {
            return
        }

        // Built here rather than read back from the store: the row the engine just wrote is
        // this, and a read would race the write it is waiting on.
        await scheduler.schedule(
            ReminderRow(
                id: reminderID,
                eventID: "",
                createdAt: Int64(Date().timeIntervalSince1970),
                notBefore: notBefore,
                status: .pending,
                target: target,
                note: nil
            ),
            authorName: authorName
        )
    }
}
