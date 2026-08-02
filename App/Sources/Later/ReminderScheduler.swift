import BuzzKit
import Foundation
import UserNotifications

/// Schedules the local notification a reminder fires.
///
/// # Why the alert is local and the reminder is not
///
/// The reminder itself lives on the relay as a `kind:30300` so every device this identity
/// owns agrees about it. The *alert* is a different thing: iOS will not let a server wake
/// this app on a schedule without a push certificate and a notification service, and none
/// of that exists here. So each device schedules its own `UNTimeIntervalNotificationTrigger`
/// for the reminders it can see, and the relay stays the record of what is owed.
///
/// The consequence, stated plainly because it is a real limit rather than an oversight: a
/// reminder set on the desktop fires on the phone only once the phone has synced it, and a
/// phone that never opens the app will not have scheduled it.
///
/// # Why identifiers are the `d` tag
///
/// Rescheduling is "remove the request under this id, add a new one" — so snoozing a
/// reminder replaces its alert instead of stacking a second one, and completing it removes
/// the alert outright. The `d` tag is the reminder's identity across every revision of its
/// event, which is exactly the lifetime an alert should have.
@MainActor
final class ReminderScheduler {
    /// The prefix on every request this app owns, so a sweep can tell its own requests
    /// apart from anything scheduled later by another feature.
    private static let identifierPrefix = "reminder."

    private let center: UNUserNotificationCenter
    private let now: () -> Date

    init(center: UNUserNotificationCenter = .current(), now: @escaping () -> Date = Date.init) {
        self.center = center
        self.now = now
    }

    /// Asks for permission, returning whether alerts may be shown.
    ///
    /// Called when a reminder is actually set rather than at launch: a permission prompt
    /// on first run, before anyone has asked for anything, is the one most reliably
    /// refused — and a refusal here costs the feature for good.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Whether alerts are allowed right now, without prompting.
    func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// Schedules (or reschedules) the alert for one reminder.
    ///
    /// A due time already in the past schedules nothing and removes any existing request:
    /// `UNTimeIntervalNotificationTrigger` rejects a non-positive interval, and firing
    /// "now" for something that came due while the app was closed would be an alert about
    /// a moment that has gone.
    func schedule(_ row: ReminderRow, authorName: String) async {
        cancel(row.id)
        guard row.status == .pending, let due = row.dueDate else { return }
        let interval = due.timeIntervalSince(now())
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = Self.body(authorName: authorName, preview: row.target?.preview ?? "")
        content.sound = .default
        // So a tap can land on the reminder that came due rather than just opening the app —
        // see ``ReminderAlerts``, which reads the first of these back.
        content.userInfo = [
            Self.reminderIDKey: row.id,
            "eventID": row.target?.eventID ?? "",
            "channelID": row.target?.channelID ?? "",
        ]

        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + row.id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        try? await center.add(request)
    }

    /// Drops the alert for a reminder that is no longer pending.
    func cancel(_ reminderID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifierPrefix + reminderID])
    }

    /// Brings the scheduled alerts in line with the reminders that are actually pending.
    ///
    /// The reconciler, run whenever the pending set changes. Scheduling on its own is not
    /// enough: a reminder completed on the *desktop* arrives here as a status change with
    /// no local action behind it, and its alert would otherwise still fire on this phone.
    func reconcile(pending: [ReminderRow], authorName: (String) -> String) async {
        let wanted = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
            .map { String($0.dropFirst(Self.identifierPrefix.count)) }

        for staleID in existing where wanted[staleID] == nil {
            cancel(staleID)
        }
        let existingIDs = Set(existing)
        for row in pending where !existingIDs.contains(row.id) {
            await schedule(row, authorName: authorName(row.target?.authorPubkey ?? ""))
        }
    }
}

// MARK: - Copy

extension ReminderScheduler {
    /// Where the reminder's `d` tag rides on the alert's payload. Named once because two
    /// sides depend on it agreeing: this schedules with it, ``ReminderAlerts`` resolves a
    /// tap through it, and a typo in either would simply open the app at the sidebar.
    ///
    /// `nonisolated` because the delegate that reads it is not on the main actor — the
    /// notification centre calls it wherever it likes, and a constant string has no actor.
    nonisolated static let reminderIDKey = "reminderID"

    /// The owner's wording, kept verbatim.
    static let title = "You asked me to remind you"

    /// How much of the message rides in the alert. The owner's number.
    static let previewLimit = 40

    /// `@Name: the first forty characters`.
    ///
    /// The name is the *message author's*, so a reminder about someone else's message says
    /// whose it was. The owner's example read `@Jarvis:` because the message he saved was
    /// one of mine; a literal would have put my name on everybody's.
    static func body(authorName: String, preview: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > previewLimit
            ? String(trimmed.prefix(previewLimit))
            : trimmed
        return "@\(authorName): \(clipped)"
    }
}
