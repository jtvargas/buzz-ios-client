import UserNotifications

/// A tap on a reminder's alert, carried from the notification centre into the app.
///
/// # Why this exists
///
/// A reminder's alert is a *local* notification (see ``ReminderScheduler``), and iOS hands a
/// tap on one to `UNUserNotificationCenter`'s delegate — one process-wide slot, with no
/// SwiftUI equivalent. So the delegate is a small object that does exactly one thing: say
/// which reminder was tapped.
///
/// # Where the tap goes
///
/// To ``onOpen``, which ``AppEnvironment`` sets to ask ``AppNavigator`` for
/// ``AppDestination/later``. The mapping lives *there* rather than here so this object stays
/// "a tap happened, on this reminder" and the object that owns both halves says what a tap
/// means — and so a tapped alert travels the one path a screen asked for from outside the
/// view tree already travels. That path is what selects the Home tab (``RootView``) before
/// ``ChannelListView`` pushes, and a value read by the sidebar alone could not do that half:
/// the tab selection lives above it, so a tap arriving while Activity is on screen would
/// push Later behind a tab nobody is looking at.
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
final class ReminderAlerts {
    /// Called with the tapped reminder's id.
    ///
    /// Set by ``AppEnvironment`` in its own `init`, which is also where this object is built
    /// — one synchronous span on the main actor with no suspension in it, so there is no
    /// moment at which the delegate below exists and this does not.
    ///
    /// The id is passed even though today's handler ignores it: it is what "open Later *on
    /// the reminder that came due*" would need, and this is the only place that fact exists.
    var onOpen: ((String) -> Void)?

    /// The delegate itself. Held because `UNUserNotificationCenter.delegate` is `weak`, and
    /// a delegate nobody retains stops being one the moment `init` returns.
    private let delegate = Delegate()

    init() {
        delegate.onOpen = { [weak self] id in self?.onOpen?(id) }
        UNUserNotificationCenter.current().delegate = delegate
    }
}

/// The notification-centre delegate, kept apart from the type above:
/// `UNUserNotificationCenterDelegate` is a plain Objective-C protocol carrying no actor
/// isolation, and mixing it into a `@MainActor` type makes the conformance the interesting
/// part of a class whose job is to forward one string.
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
