import HivePushKit
import NostrCore
import OSLog
import UserNotifications

/// Resolves a reconnect wake from App Group leases, never from APNs-supplied
/// relay URLs or filters. No app database, profile lookup, or media downloads.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "Hive", category: "NotificationService")
    private let currentWake = OSAllocatedUnfairLock<PushWake?>(initialState: nil)
    private let loadCommunities: @Sendable () throws -> [PushCommunitySnapshot]
    private let resolver: PushWakeResolver

    override init() {
        loadCommunities = {
            guard let appGroup = AppGroup(), let store = PushSnapshotStore(appGroup: appGroup) else { return [] }
            return try store.loadAll()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        resolver = PushWakeResolver(client: PushQueryClient(
            transport: URLSessionHTTPTransport(session: URLSession(configuration: configuration))
        ))
        super.init()
    }

    /// Uses the same didReceive/expiry path with an isolated store and transport.
    init(
        loadCommunities: @escaping @Sendable () throws -> [PushCommunitySnapshot],
        resolver: PushWakeResolver
    ) {
        self.loadCommunities = loadCommunities
        self.resolver = resolver
        super.init()
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let wake = PushWake(content: request.content, handler: contentHandler)
        let previous = currentWake.withLock { current in
            let previous = current
            current = wake
            return previous
        }
        previous?.finish()
        Self.log.info("Resolving push wake")
        let task = Task { @Sendable [loadCommunities, resolver, wake] in
            defer { wake.finish() }
            do {
                let communities = try loadCommunities()
                await resolver.resolve(communities: communities) { wake.update($0) }
            } catch {
                Self.log.error("Reading push snapshots failed; preserving original content")
            }
        }
        wake.attach(task)
    }

    override func serviceExtensionTimeWillExpire() {
        Self.log.warning("Service time expiring; delivering best available content")
        currentWake.withLock { $0 }?.finish()
    }
}

/// The system's expiry callback can race query completion. All mutable state is
/// lock-protected; callbacks and cancellation run outside the lock. Each request
/// owns its delivery, so a late result can never complete a subsequent wake.
private final class PushWake: Sendable {
    private struct State {
        var content: UNNotificationContent
        var handler: ((UNNotificationContent) -> Void)?
        var task: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        state = OSAllocatedUnfairLock(uncheckedState: State(content: content, handler: handler))
    }

    func attach(_ task: Task<Void, Never>) {
        let finished = state.withLockUnchecked { state in
            guard state.handler != nil else { return true }
            state.task = task
            return false
        }
        if finished { task.cancel() }
    }

    func update(_ notification: PushNotification) {
        state.withLockUnchecked { state in
            guard state.handler != nil else { return }
            state.content = notification.applying(to: state.content)
        }
    }

    func finish() {
        let delivery = state.withLockUnchecked { state -> State? in
            guard state.handler != nil else { return nil }
            let delivery = state
            state.handler = nil
            state.task = nil
            return delivery
        }
        guard let delivery else { return }
        delivery.task?.cancel()
        delivery.handler?(delivery.content)
    }
}
