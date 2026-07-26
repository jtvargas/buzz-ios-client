import BuzzKit
import Observation

@MainActor
@Observable
final class ChannelDetailsModel {
    private(set) var members: [MemberProfile] = []
    private(set) var hasLoaded = false

    private let channelID: String
    private let store: BuzzEventStore

    init(channelID: String, store: BuzzEventStore) {
        self.channelID = channelID
        self.store = store
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let rows = (try? store.channelMembers(channelID)) ?? []
                await apply(rows)
            }
        } catch {
            // Keep the last good roster when the observation is cancelled.
        }
    }

    private func apply(_ rows: [MemberProfile]) {
        members = rows
        hasLoaded = true
    }
}
