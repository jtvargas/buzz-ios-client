import Observation
import UserNotifications

/// A tap on a reminder's alert, carried from the notification centre into the view tree.
///
/// # Why this exists
///
/// A reminder's alert is a *local* notification (see ``ReminderScheduler``), and iOS hands a
/// tap on one to `UNUserNotificationCenter`'s delegate — one process-wide slot, with no
/// SwiftUI equivalent. So the delegate is a small object that does exactly one thing: say
/// which reminder was tapped. ``ChannelListView`` watches ``opened``, opens Later, and
/// flashes the row that came due.
///
/// # Why the delegate is installed in `init`
///
/// "The delegate must be set before the application returns from
/// `application:didFinishLaunchingWithOptions:`" — `UNUserNotificationCenter.h`. A tap that
/// *launches* the app is delivered right after that returns, so a delegate installed from a
/// `.task` — which runs after the first render — would miss precisely the case this feature
/// is for. This object is built by ``AppEnvironment``, which is built in ``HiveApp``'s stored
/// property, which runs during launch.
@MainActor
@Observable
final class ReminderAlerts {
    /// The reminder whose alert was tapped and has not been acted on yet.
    ///
    /// Cleared by the screen that takes it, so a second tap on the same reminder is a second
    /// signal rather than a value that never changes and therefore never fires an `onChange`.
    var opened: String?

    /// The delegate itself. Held because `UNUserNotificationCenter.delegate` is `weak`, and
    /// a delegate nobody retains stops being one the moment `init` returns.
    private let delegate = Delegate()

    init() {
        delegate.onOpen = { [weak self] id in self?.opened = id }
        UNUserNotificationCenter.current().delegate = delegate
    }
}

/// The notification-centre delegate, kept apart from the observable state above:
/// `UNUserNotificationCenterDelegate` is a plain Objective-C protocol carrying no actor
/// isolation, and mixing it into an `@Observable @MainActor` type makes the conformance the
/// interesting part of a class whose job is to forward one string.
private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    /// Set once, from the main actor, before this delegate is installed.
    var onOpen: (@MainActor @Sendable (String) -> Void)?

    /// Shows the alert even while Hive is open.
    ///
    /// Without this, iOS silently drops a notification whose app is in the foreground — and
    /// the foreground is exactly where anyone testing the one-minute preset is standing. A
    /// reminder is the reader's own request from a few minutes ago, so it is worth a banner
    /// over the conversation they are reading.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// The tap. Only the id crosses to the main actor — `UNNotificationResponse` itself
    /// stays here.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let id = userInfo[ReminderScheduler.reminderIDKey] as? String, !id.isEmpty else { return }
        await onOpen?(id)
    }
}
