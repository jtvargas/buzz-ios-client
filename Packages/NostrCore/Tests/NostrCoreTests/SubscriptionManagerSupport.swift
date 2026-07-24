import Foundation
@testable import NostrCore

/// A scripted ``EventSink`` that records every delivery so a test can assert on
/// batch shapes, phases, the EOSE boundary, and the error surface.
actor RecordingSink: EventSink {
    struct Delivery: Sendable {
        let events: [NostrEvent]
        let subscription: SubscriptionID
        let phase: IngestPhase
    }

    struct Closure: Sendable {
        let subscription: SubscriptionID
        let error: SubscriptionError
    }

    private(set) var deliveries: [Delivery] = []
    private(set) var endOfStoredEventsCount = 0
    private(set) var closures: [Closure] = []

    func ingest(batch: [NostrEvent], subscription: SubscriptionID, phase: IngestPhase) async {
        deliveries.append(Delivery(events: batch, subscription: subscription, phase: phase))
    }

    func endOfStoredEvents(subscription _: SubscriptionID) async {
        endOfStoredEventsCount += 1
    }

    func subscriptionClosed(subscription: SubscriptionID, error: SubscriptionError) async {
        closures.append(Closure(subscription: subscription, error: error))
    }

    var ingestCallCount: Int {
        deliveries.count
    }

    var batchSizes: [Int] {
        deliveries.map(\.events.count)
    }

    var phases: [IngestPhase] {
        deliveries.map(\.phase)
    }

    var totalEventCount: Int {
        deliveries.reduce(0) { $0 + $1.events.count }
    }

    var closureCount: Int {
        closures.count
    }

    func closureAt(_ index: Int) -> Closure {
        closures[index]
    }
}

/// A manager over a never-connected connection, for driving delivery directly
/// through ``SubscriptionManager/route(_:)`` without a socket. Instant live tick
/// unless a gate is injected.
func idleManager(
    signer: some EventSigner,
    config: SubscriptionManagerConfig = .default,
    liveFlushSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
) -> SubscriptionManager {
    let connection = makeInertConnection(signer: signer, transports: TransportQueue([]))
    return SubscriptionManager(
        connection: connection,
        signer: signer,
        config: config,
        liveFlushSleep: liveFlushSleep
    )
}

/// Feeds one event to a subscription through the manager's routing seam.
func feedEvent(_ manager: SubscriptionManager, _ id: SubscriptionID, index: Int, createdAt: Int64) async {
    await manager.route(.event(subscriptionID: id.rawValue, event: makeEvent(index: index, createdAt: createdAt)))
}

/// Builds a bare event with a distinct id and the given timestamp. The manager
/// treats events opaquely — validity is the store's concern — so the fields need
/// only round-trip through the wire codec.
func makeEvent(index: Int, createdAt: Int64, kind: EventKind = .channelMessage) -> NostrEvent {
    NostrEvent(
        id: "event-\(index)",
        pubkey: String(repeating: "a", count: 64),
        createdAt: createdAt,
        kind: kind,
        tags: [],
        content: "body-\(index)",
        sig: String(repeating: "0", count: 128)
    )
}

/// The filters inside a `["REQ", id, ...]` frame the client sent.
func requestFilters(from frame: String) throws -> [Filter] {
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8))
    guard case let .req(_, filters) = message else {
        throw SubscriptionTestError.notExpectedFrame(frame)
    }
    return filters
}

/// The subscription id inside a `["CLOSE", id]` frame the client sent.
func closeSubscriptionID(from frame: String) throws -> String {
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8))
    guard case let .close(subscriptionID) = message else {
        throw SubscriptionTestError.notExpectedFrame(frame)
    }
    return subscriptionID
}

enum SubscriptionTestError: Error {
    case notExpectedFrame(String)
}
