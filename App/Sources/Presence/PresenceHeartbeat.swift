import BuzzKit
import Foundation
import NostrCore

/// Publishes this device's own presence: an `"online"` heartbeat every 60 s while
/// the app is foregrounded, and a single `"offline"` on background.
///
/// Foreground-only by construction: the beat loop runs only between
/// ``startForeground()`` and ``stopBackground()``, which the composition root drives
/// off the scene phase. Presence sends are ephemeral and fire-and-forget — a failed
/// heartbeat is dropped, never retried, because a stale heartbeat resent minutes
/// later would misreport liveness.
///
/// Presence is workspace-global, so a heartbeat carries no `h` tag — only the bare
/// status in its content, plus the structured `["status", …]` tag the upstream
/// builder also writes. `"offline"` is the departure the relay clears its
/// presence state on.
@MainActor
final class PresenceHeartbeat {
    private let publisher: any EphemeralPublishing
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - publisher: where heartbeats go — the engine in production.
    ///   - interval: the beat cadence. Default 60 s (the upstream heartbeat).
    ///   - sleep: the cadence sleep, injected so a test drives the loop without real
    ///     time. Must respect cancellation so ``stopBackground()`` ends the loop
    ///     promptly.
    init(
        publisher: any EphemeralPublishing,
        interval: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.publisher = publisher
        self.interval = interval
        self.sleep = sleep
    }

    /// Begins beating `"online"` immediately and then every `interval`, until
    /// ``stopBackground()``. Idempotent: a second call while a loop is already
    /// running is a no-op, so a redundant `.active` never spawns a second beater.
    func startForeground() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.runForeground() }
    }

    /// The beat loop: an immediate `"online"`, then one each `interval`. Ends when
    /// the injected sleep throws (cancellation). Not private so a test can drive it
    /// directly with a self-terminating sleep, asserting the cadence without a timer.
    func runForeground() async {
        while !Task.isCancelled {
            await beat()
            do {
                try await sleep(interval)
            } catch {
                return
            }
        }
    }

    /// Ends the beat loop and publishes a single `"offline"`. Awaits the loop's exit
    /// first, so no `"online"` beat can trail the `"offline"` and leave a peer's dot
    /// stuck on.
    func stopBackground() async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value
        await goOffline()
    }

    /// Publishes one `"online"` heartbeat.
    func beat() async {
        await publisher.publishEphemeral(kind: .presence, content: "online", tags: Self.statusTags("online"))
    }

    /// Publishes one `"offline"` departure.
    func goOffline() async {
        await publisher.publishEphemeral(kind: .presence, content: "offline", tags: Self.statusTags("offline"))
    }

    /// The upstream presence tag shape: the status mirrored into a `["status", …]`
    /// tag beside the content. No `h` tag — presence is channel-less.
    static func statusTags(_ status: String) -> [[String]] {
        [["status", status]]
    }
}
