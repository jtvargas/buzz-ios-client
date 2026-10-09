import HivePushKit
import OSLog
import UIKit
import UserNotifications

/// Handles the UIKit lifecycle callbacks required for push registration:
/// device token delivery and registration failure.
///
/// Installed as a `UIApplicationDelegateAdaptor` in ``HiveApp``, this class is
/// the bridge between UIKit's push callbacks and ``EnrollmentDriver``'s actor.
/// It does not own the enrollment driver — that belongs to ``AppEnvironment`` —
/// but it holds a reference to route tokens through.
///
/// Kept deliberately small: it does exactly two things (token delivery, failure
/// delivery) and nothing else. The enrollment flow, permission request, and lease
/// management all live in ``EnrollmentDriver``.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    /// The enrollment driver for the active community, set by
    /// ``PushEnrollmentCoordinator`` when enrollment starts. Nil'd on teardown.
    var enrollmentDriver: EnrollmentDriver?

    private static let log = Logger(subsystem: "Hive", category: "PushRegistrar")

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.log.info("Received device token: \(hex.prefix(8))…")
        guard let driver = enrollmentDriver else { return }
        Task { await driver.didReceiveDeviceToken(hex) }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Self.log.error("Remote notification registration failed: \(String(describing: error))")
        guard let driver = enrollmentDriver else { return }
        Task { await driver.didFailToRegisterForRemoteNotifications(error) }
    }
}

// MARK: - Notification permission

/// Requests notification permission in the standard UNUserNotificationCenter way.
///
/// A free function rather than a method on anything, because the permission request
/// is a one-shot system call that belongs to no object. The enrollment driver calls
/// this through its injected `requestPermission` closure.
func requestNotificationPermission() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    return granted
}
