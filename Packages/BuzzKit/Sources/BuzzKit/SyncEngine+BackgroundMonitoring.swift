import NostrCore

public extension SyncEngine {
    /// The caller must hold real OS background execution time. This only changes
    /// Hive's connection policy; it does not obtain execution time from iOS.
    func retainConnectionForMonitoring(_ retained: Bool) async {
        retainsConnectionForMonitoring = retained
        guard !isStopped else { return }
        if retained {
            await connection.foreground()
        } else if !isForeground {
            await connection.background()
        }
    }

    /// A suspension that was already closing its transport when monitoring took
    /// ownership can finish late. Resume it on the next monitoring tick.
    func refreshMonitoringConnection() async -> Bool {
        guard !isStopped else { return false }
        if await connection.state == .suspended, retainsConnectionForMonitoring, !isStopped {
            await connection.foreground()
        }
        return await connection.state == .ready
    }
}
