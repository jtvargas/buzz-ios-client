import HivePushKit
import OSLog
import UserNotifications

/// Hive's Notification Service Extension: woken by APNs for every push carrying
/// `mutable-content: 1`, before the notification is shown.
///
/// Today it is the platform scaffold and nothing more. It logs the wake payload,
/// proves it can see what the app left for it — the per-community snapshots in
/// the App Group and the identity keys in the shared Keychain — and hands the
/// notification back exactly as it arrived. Resolving a wake into a real title
/// and body (query the relay as the reader, verify, render) is the next ticket's
/// work and slots in where ``didReceive(_:withContentHandler:)`` currently
/// finishes.
///
/// Two constraints shape everything here. The system gives this process about
/// thirty seconds and then calls ``serviceExtensionTimeWillExpire()``, after which
/// whatever content has been handed back is what the reader sees — so the
/// original content is retained from the first line and delivered on expiry.
/// And the process has a 24 MB memory ceiling, which is why it links
/// `HivePushKit` and `NostrCore` and none of the app's UI or database stack.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "Hive", category: "NotificationService")

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content

        Self.log.info("Woken for request \(request.identifier, privacy: .public)")
        Self.log.info("Payload: \(Self.describe(request.content.userInfo), privacy: .public)")
        logSharedState()

        finish()
    }

    override func serviceExtensionTimeWillExpire() {
        Self.log.warning("Service time expiring; delivering the content as received")
        finish()
    }

    /// Hands back the best content we have, exactly once.
    private func finish() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
        contentHandler(bestAttemptContent)
    }

    // MARK: - Shared state

    /// What the app has shared with us: a line per community snapshot, saying whether
    /// the identity key it names is reachable from this process. Never the key itself.
    private func logSharedState() {
        guard let appGroup = AppGroup() else {
            Self.log.error("No \(AppGroup.infoPlistKey, privacy: .public) in Info.plist")
            return
        }
        guard let store = PushSnapshotStore(appGroup: appGroup) else {
            Self.log.error("No container for App Group \(appGroup.identifier, privacy: .public)")
            return
        }
        let snapshots: [PushCommunitySnapshot]
        do {
            snapshots = try store.loadAll()
        } catch {
            Self.log.error("Reading snapshots failed: \(String(describing: error), privacy: .public)")
            return
        }
        Self.log.info(
            """
            App Group \(appGroup.identifier, privacy: .public): \
            \(snapshots.count, privacy: .public) community snapshot(s)
            """
        )
        for snapshot in snapshots {
            let key = IdentityKeychain.hasStoredKey(account: snapshot.keychainAccount) ? "present" : "missing"
            Self.log.info(
                """
                Community \(snapshot.communityID, privacy: .public) \
                "\(snapshot.name, privacy: .public)" \
                relay=\(snapshot.relayURL.absoluteString, privacy: .public) \
                gateway=\(snapshot.gatewayURL.absoluteString, privacy: .public) \
                key=\(key, privacy: .public)
                """
            )
        }
    }

    private static func describe(_ userInfo: [AnyHashable: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(userInfo),
              let data = try? JSONSerialization.data(withJSONObject: userInfo, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return String(describing: userInfo)
        }
        return json
    }
}
