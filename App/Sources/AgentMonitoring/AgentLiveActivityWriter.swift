import ActivityKit
import Foundation

/// Serializes ActivityKit writes so a slow update cannot overtake a final state.
@MainActor
final class AgentLiveActivityWriter {
    private(set) var activity: Activity<AgentActivityAttributes>?
    private var pending: Task<Void, Never>?
    private var attributesSize = 0

    func start(attributes: AgentActivityAttributes, state: AgentActivityAttributes.ContentState) async throws {
        await pending?.value
        // A killed process may leave its custom card behind. Reclaim only our type.
        for previous in Activity<AgentActivityAttributes>.activities {
            await previous.end(nil, dismissalPolicy: .immediate)
        }
        try Task.checkCancellation()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw WriterError.activitiesDisabled }
        attributesSize = try JSONEncoder().encode(attributes).count
        activity = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
    }

    func update(_ state: AgentActivityAttributes.ContentState) {
        guard let activity else { return }
        let previous = pending
        let content = content(state)
        pending = Task {
            await previous?.value
            await activity.update(content)
        }
    }

    func finish(_ state: AgentActivityAttributes.ContentState?, dismissImmediately: Bool) async {
        let activity = activity
        self.activity = nil
        let previous = pending
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let completion = Task {
            await previous?.value
            if let activity {
                await activity.end(
                    content,
                    dismissalPolicy: dismissImmediately ? .immediate : .after(.now.addingTimeInterval(60))
                )
            }
        }
        pending = completion
        await completion.value
    }

    func removeOrphans() async {
        guard activity == nil else { return }
        await pending?.value
        for previous in Activity<AgentActivityAttributes>.activities {
            await previous.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func content(
        _ state: AgentActivityAttributes.ContentState
    ) -> ActivityContent<AgentActivityAttributes.ContentState> {
        var bounded = state
        // ActivityKit's total budget is 4 KB, including immutable attributes.
        // Measure UTF-8 bytes so emoji and long conversation IDs cannot overflow it.
        while !bounded.rows.isEmpty,
              ((try? JSONEncoder().encode(bounded).count) ?? 0) + attributesSize > 3_900 {
            bounded.rows.removeLast()
        }
        return ActivityContent(state: bounded, staleDate: state.updatedAt.addingTimeInterval(12))
    }

    enum WriterError: Error { case activitiesDisabled }
}
