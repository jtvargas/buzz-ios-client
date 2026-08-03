import BuzzKit
import Foundation

/// Setting a reminder from a conversation, in one place.
///
/// Both the channel and a thread offer "Remind Me" on the same sheet, and both have to do
/// the same four things in the same order: ask for notification permission, publish the
/// reminder, and schedule the alert. A second copy is a second place for the two to drift
/// — the same reasoning that made ``MessageActionsSheet`` one sheet rather than two.
///
/// # Why it takes the environment rather than an engine and a scheduler
///
/// It used to take the engine, and each caller guarded it out of ``AppEnvironment`` first. The
/// scheduler was a defaulted parameter neither caller passed — which stopped being harmless the
/// moment there was an app-wide notification switch to read, because a `ReminderScheduler()`
/// built with no arguments is one with that switch at its permissive default. A caller who
/// forgot it would have scheduled an alert past a reader's decision.
///
/// Both are now built here, from the one object that has both. There is nothing for a caller to
/// forget, and the switch is read at the moment the alert is created rather than captured
/// wherever the sheet happened to be assembled.
@MainActor
enum ReminderCreation {
    static func set(
        _ row: TimelineRow,
        channelID: String,
        due: Date,
        authorName: String,
        in environment: AppEnvironment
    ) async {
        guard let engine = environment.engine else { return }
        // Constructed per call: it holds no state of its own, and
        // `UNUserNotificationCenter.current()` is already the process-wide singleton everything
        // it does goes through.
        let scheduler = ReminderScheduler(
            notificationsEnabled: { environment.settings.notificationsEnabled }
        )
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
