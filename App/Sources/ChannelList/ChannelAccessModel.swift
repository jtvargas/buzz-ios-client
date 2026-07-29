import BuzzKit
import Observation

@MainActor
@Observable
final class ChannelAccessModel {
    private(set) var state: ChannelAccessState = .active

    private let channelID: String
    private let identity: String?
    private let store: BuzzEventStore

    init(channelID: String, identity: String?, store: BuzzEventStore) {
        self.channelID = channelID
        self.identity = identity
        self.store = store
    }

    var isWritable: Bool { state.isWritable }

    nonisolated func run() async {
        guard let identity else { return }
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let value = (try? store.channelAccessState(
                    identity: identity,
                    channel: channelID
                )) ?? .unavailable
                await apply(value)
            }
        } catch {
            // Cancellation keeps the last known access state on screen.
        }
    }

    private func apply(_ value: ChannelAccessState) {
        state = value
    }
}
