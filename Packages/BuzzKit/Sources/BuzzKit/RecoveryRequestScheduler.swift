import Foundation

/// Admission for catch-up reads, shared by windows, threads and speculative fetches.
/// One background request leaves room for the conversation the reader opens next.
actor RecoveryRequestScheduler {
    enum Destination: Hashable, Sendable {
        case channel(String)
        case thread(String)
        case background
    }

    enum Phase: Int, Sendable {
        case visibleHistory
        case head
        case gap
        case speculative
    }

    private struct Request {
        let id: UUID
        let destination: Destination
        let phase: Phase
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var pending: [Request] = []
    private var active: [UUID: Destination] = [:]
    private var priorities: [Destination] = []
    private var visible: Set<Destination> = []

    func prioritise(_ destinations: [Destination], visible: Set<Destination>) {
        priorities = destinations
        self.visible = visible
        admit()
    }

    func acquire(_ destination: Destination, phase: Phase) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(Request(id: id, destination: destination, phase: phase, continuation: continuation))
                admit()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        active.removeValue(forKey: id)
        admit()
    }

    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(throwing: CancellationError())
        admit()
    }

    private func admit() {
        while active.count < 2 {
            let hasBackground = active.values.contains { !visible.contains($0) }
            let eligible = pending.indices.filter {
                !hasBackground || visible.contains(pending[$0].destination)
            }
            guard let index = eligible.min(by: { ranksBefore(pending[$0], pending[$1]) }) else { return }
            let request = pending.remove(at: index)
            active[request.id] = request.destination
            request.continuation.resume(returning: request.id)
        }
    }

    private func ranksBefore(_ lhs: Request, _ rhs: Request) -> Bool {
        if lhs.phase != rhs.phase { return lhs.phase.rawValue < rhs.phase.rawValue }
        if lhs.phase == .gap { return false }
        let left = priorities.firstIndex(of: lhs.destination) ?? Int.max
        let right = priorities.firstIndex(of: rhs.destination) ?? Int.max
        // `min` keeps the first equal-ranked request, rotating gap pages fairly.
        return left < right
    }
}
